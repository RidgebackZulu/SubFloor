import Foundation

/// WSPR modulator for tests and the signal bench: one 120 s slot of audio.
///
/// Continuous-phase 4-FSK: symbol s (0…3, from `WSPRCodec.channelSymbols`) is the tone
/// `audioHz + (s − 1.5) × 12000/8192` Hz, so `audioHz` is the centre of the ~6 Hz wide signal, as WSPR
/// frequencies are reported. Each symbol lasts 8192/12000 s ≈ 0.683 s (8192 samples at 12 kHz); the
/// 162 symbols start 1 s into the slot and end at about 111.6 s. The rest of the buffer is silence.
public enum WSPREncoder {
    /// Tone spacing and keying rate, 12000/8192 ≈ 1.4648 Hz.
    public static let toneSpacing = 12_000.0 / 8_192
    /// Samples per symbol at 12 kHz.
    public static let samplesPerSymbol = 8_192
    /// Slot length.
    public static let slotSeconds = 120.0
    /// Start of the transmission within the slot.
    public static let startSeconds = 1.0

    public static func audio(call: String, grid: String, powerDbm: Int, audioHz: Double,
                             sampleRate: Double = 12_000, amplitude: Float = 0.5) -> [Float]? {
        guard sampleRate > 0, let symbols = WSPRCodec.channelSymbols(call: call, grid: grid, powerDbm: powerDbm)
        else { return nil }
        var out = [Float](repeating: 0, count: Int((slotSeconds * sampleRate).rounded()))
        let start = Int((startSeconds * sampleRate).rounded())
        let symbolSeconds = 1 / toneSpacing
        var phase = 0.0
        var n = start
        for (k, symbol) in symbols.enumerated() {
            // Symbol k covers [start + k·T, start + (k+1)·T) in samples, rounded at each boundary.
            let end = min(out.count, start + Int((Double(k + 1) * symbolSeconds * sampleRate).rounded()))
            let step = 2 * Double.pi * (audioHz + (Double(symbol) - 1.5) * toneSpacing) / sampleRate
            while n < end {
                out[n] = amplitude * Float(sin(phase))
                phase += step
                if phase > 2 * .pi { phase -= 2 * .pi }
                n += 1
            }
        }
        return out
    }
}
