import Foundation

/// PSK31 modulator (BPSK31 or QPSK31) for tests and the signal bench.
///
/// Layout: `leadInSeconds` of silence, an idle preamble of phase reversals (Varicode zeros), the
/// text (each character followed by "00"), then a postamble of steady carrier (ones), as G3PLX
/// describes so the receiver can sync on the reversals and squelch on their absence.
///
/// Shaping: each symbol interval blends the previous and the new symbol with a cosine,
/// `c[k-1]·½(1+cos πτ/T) + c[k]·½(1−cos πτ/T)`, so a reversal follows a full cosine and a steady
/// symbol is constant carrier. That is a train of raised-cosine pulses two symbols long. The first and
/// last symbols ramp from and to silence the same way.
public struct PSK31Encoder {
    public static let symbolRate = 31.25
    /// Idle reversals before the text, in symbols.
    public static let preambleSymbols = 32
    /// Steady carrier after the text, in symbols.
    public static let postambleSymbols = 32

    public static func audio(text: String, frequencyHz: Double, qpsk: Bool = false, sampleRate: Double = 12_000,
                             leadInSeconds: Double = 1, amplitude: Float = 0.5) -> [Float] {
        audio(text: text, qpsk: qpsk, sampleRate: sampleRate, leadInSeconds: leadInSeconds, amplitude: amplitude,
              frequencyAt: { _ in frequencyHz })
    }

    /// As `audio(text:frequencyHz:...)`, with the carrier frequency a function of time in seconds from
    /// the start of the buffer (for drift tests). `invertedSense` negates every phase shift, which is
    /// what a transmission on the opposite sideband looks like (it matters only for QPSK).
    public static func audio(text: String, qpsk: Bool = false, sampleRate: Double = 12_000,
                             leadInSeconds: Double = 1, amplitude: Float = 0.5,
                             frequencyAt: (Double) -> Double, invertedSense: Bool = false) -> [Float] {
        let sense = invertedSense ? -1.0 : 1.0
        let phases = symbolPhases(bits: bits(for: text), qpsk: qpsk).map { $0 * sense }
        let samplesPerSymbol = sampleRate / symbolRate
        let lead = Int(leadInSeconds * sampleRate)
        // One extra symbol interval ramps the last symbol down to silence.
        let body = Int((Double(phases.count + 1) * samplesPerSymbol).rounded())
        var out = [Float](repeating: 0, count: lead + body)
        var carrier = 0.0
        for n in 0..<(lead + body) {
            let t = Double(n) / sampleRate
            carrier += 2 * .pi * frequencyAt(t) / sampleRate
            if carrier > 2 * .pi { carrier -= 2 * .pi }
            guard n >= lead else { continue }
            let pos = Double(n - lead) / samplesPerSymbol
            let k = Int(pos)
            let frac = pos - Double(k)
            // Interval k blends symbol k-1 (silence before the first) into symbol k (silence after the last).
            let w = 0.5 * (1 - cos(.pi * frac))
            var re = 0.0, im = 0.0
            if k - 1 >= 0 && k - 1 < phases.count {
                re += (1 - w) * cos(phases[k - 1]); im += (1 - w) * sin(phases[k - 1])
            }
            if k < phases.count {
                re += w * cos(phases[k]); im += w * sin(phases[k])
            }
            out[n] = amplitude * Float(re * cos(carrier) - im * sin(carrier))
        }
        return out
    }

    /// Channel bits: preamble zeros, Varicode with "00" after each character, postamble ones.
    static func bits(for text: String) -> [Bool] {
        var bits = [Bool](repeating: false, count: preambleSymbols)
        for c in text {
            let code = Varicode.encode(c)
            guard !code.isEmpty else { continue }
            bits += code + [false, false]
        }
        bits += [Bool](repeating: true, count: postambleSymbols)
        return bits
    }

    /// Absolute carrier phase of each symbol. BPSK: a 0 reverses the phase, a 1 keeps it. QPSK: the
    /// G3PLX convolutional code turns each bit into a shift of 0, +90°, 180° or −90°.
    static func symbolPhases(bits: [Bool], qpsk: Bool) -> [Double] {
        var phase = 0.0
        var window = 0
        return bits.map { bit in
            if qpsk {
                window = ((window << 1) | (bit ? 1 : 0)) & 31
                phase += Double(QPSKCode.phaseShift(window: window)) * .pi / 2
            } else if !bit {
                phase += .pi
            }
            return phase
        }
    }
}
