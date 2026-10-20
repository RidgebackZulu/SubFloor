import Foundation

/// RTTY (FSK) modulator for tests and the signal bench.
///
/// Layout: `leadInSeconds` of silence, `idleBits` of steady mark, an LTRS, the text's Baudot codes,
/// then `idleBits` of mark again. Each character is a start bit (space), five data bits (bit 0
/// first) and 1.5 stop bits (mark). The keying is phase-continuous with instantaneous frequency
/// steps, as an AFSK or direct-FSK transmitter produces.
///
/// The mark tone is the upper one (`centerHz + shiftHz/2`) in normal polarity; `reverse` swaps the
/// tones, which is what a transmission received on the opposite sideband looks like.
public struct RTTYEncoder {
    /// Steady mark before and after the characters, in bits.
    public static let idleBits = 8.0
    public static let stopBits = 1.5

    public static func audio(text: String, centerHz: Double, baud: Double = 45.45, shiftHz: Double = 170,
                             reverse: Bool = false, sampleRate: Double = 12_000, amplitude: Float = 0.5,
                             leadInSeconds: Double = 1) -> [Float] {
        audio(text: text, baud: baud, shiftHz: shiftHz, reverse: reverse, sampleRate: sampleRate, amplitude: amplitude,
              leadInSeconds: leadInSeconds, centerAt: { _ in centerHz })
    }

    /// As `audio(text:centerHz:...)`, with the centre frequency a function of time in seconds from the
    /// start of the buffer (for drift tests).
    public static func audio(text: String, baud: Double = 45.45, shiftHz: Double = 170, reverse: Bool = false,
                             sampleRate: Double = 12_000, amplitude: Float = 0.5, leadInSeconds: Double = 1,
                             centerAt: (Double) -> Double) -> [Float] {
        audio(text: text, baud: baud, shiftHz: shiftHz, reverse: reverse, sampleRate: sampleRate, amplitude: amplitude,
              leadInSeconds: leadInSeconds, centerAt: centerAt, upperToneGain: { _ in 1 })
    }

    /// As above, with the upper tone scaled by `upperToneGain(t)` (selective fading, for tests).
    static func audio(text: String, baud: Double = 45.45, shiftHz: Double = 170, reverse: Bool = false,
                      sampleRate: Double = 12_000, amplitude: Float = 0.5, leadInSeconds: Double = 1,
                      centerAt: (Double) -> Double, upperToneGain: (Double) -> Float) -> [Float] {
        let marks = keying(codes: [Baudot.ltrs] + Baudot.encode(text))
        let bitSeconds = 1 / baud
        let lead = Int(leadInSeconds * sampleRate)
        let body = Int((Double(marks.count) * 0.5 * bitSeconds * sampleRate).rounded())
        var out = [Float](repeating: 0, count: lead + body)
        var phase = 0.0
        for n in lead..<(lead + body) {
            let t = Double(n) / sampleRate
            // Half-bit slots: the 1.5 stop bits make every boundary a multiple of half a bit.
            let slot = min(Int((t - Double(lead) / sampleRate) / (0.5 * bitSeconds)), marks.count - 1)
            let upper = marks[slot] != reverse
            phase += 2 * .pi * (centerAt(t) + (upper ? 1 : -1) * shiftHz / 2) / sampleRate
            if phase > 2 * .pi { phase -= 2 * .pi }
            out[n] = amplitude * (upper ? upperToneGain(t) : 1) * Float(sin(phase))
        }
        return out
    }

    /// Mark (true) or space for each half-bit of the transmission: idle, characters, idle.
    static func keying(codes: [UInt8]) -> [Bool] {
        let idle = [Bool](repeating: true, count: Int(2 * idleBits))
        var halves = idle
        let stopHalves = Int(2 * stopBits)
        for code in codes {
            halves += [false, false]
            for k in 0..<5 {
                let bit = (code >> k) & 1 == 1
                halves += [bit, bit]
            }
            halves += [Bool](repeating: true, count: stopHalves)
        }
        return halves + idle
    }
}
