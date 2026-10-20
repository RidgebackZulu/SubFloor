import CFT8
import Foundation

/// FT8 modulator for tests and the signal bench: one 15 s slot of audio.
///
/// The message is packed and encoded to 79 channel tones by the vendored ft8_lib (`cft8_encode`:
/// its `ftx_message_encode` packer, CRC-14, LDPC (174,91), Gray map and Costas syncs). The waveform is
/// ft8_lib's GFSK (`synth_gfsk` in its gen_ft8 demo, MIT): BT = 2.0, 0.16 s symbols, 6.25 Hz tone
/// spacing, the frequency pulse truncated to three symbols, and raised-cosine ramps over the first
/// and last eighth of a symbol. Tone t sits at `audioHz + 6.25·t` Hz, so `audioHz` is tone 0, the
/// frequency WSJT-X and ft8_lib report. The transmission starts 0.5 s into the slot and lasts 12.64 s;
/// the rest of the buffer is silence.
public enum FT8Encoder {
    public static let symbolSeconds = 0.16
    public static let toneSpacing = 6.25
    public static let toneCount = 79
    /// GFSK bandwidth-time product.
    public static let bt = 2.0
    public static let slotSeconds = 15.0
    /// Start of the transmission within the slot.
    public static let startSeconds = 0.5

    /// One slot of audio holding `message` (case-insensitive), or nil if ft8_lib cannot pack it.
    public static func audio(message: String, audioHz: Double, sampleRate: Double = 12_000,
                             amplitude: Float = 0.5) -> [Float]? {
        guard sampleRate > 0, sampleRate.isFinite, let tones = tones(message: message) else { return nil }
        var out = [Float](repeating: 0, count: Int((slotSeconds * sampleRate).rounded()))
        let wave = waveform(tones: tones, audioHz: audioHz, sampleRate: sampleRate)
        let start = Int((startSeconds * sampleRate).rounded())
        for (i, x) in wave.enumerated() where start + i < out.count { out[start + i] = amplitude * x }
        return out
    }

    /// The 79 channel tones (0…7) of `message` (case-insensitive), or nil if it cannot be packed.
    public static func tones(message: String) -> [UInt8]? {
        var tones = [UInt8](repeating: 0, count: toneCount)
        let ok = message.uppercased().withCString { text in
            tones.withUnsafeMutableBufferPointer { cft8_encode(text, $0.baseAddress) }
        }
        return ok == 1 ? tones : nil
    }

    /// Unit-amplitude GFSK for `tones`, `round(0.16·sampleRate)` samples per symbol, tone 0 at `audioHz`.
    static func waveform(tones: [UInt8], audioHz: Double, sampleRate: Double) -> [Float] {
        let n = Int((symbolSeconds * sampleRate).rounded())
        guard n > 0, !tones.isEmpty else { return [] }
        let count = tones.count * n
        // Phase increment per sample, over the symbols plus one dummy symbol at each end that repeats
        // the first and last tone (ft8_lib's construction).
        let peak = 2 * Double.pi / Double(n)
        var dphi = [Double](repeating: 2 * Double.pi * audioHz / sampleRate, count: count + 2 * n)
        let pulse = gaussianPulse(samplesPerSymbol: n)
        for (i, tone) in tones.enumerated() where tone != 0 {
            let base = i * n
            let scale = peak * Double(tone)
            for j in 0..<(3 * n) { dphi[base + j] += scale * pulse[j] }
        }
        let first = peak * Double(tones[0]), last = peak * Double(tones[tones.count - 1])
        for j in 0..<(2 * n) {
            dphi[j] += first * pulse[j + n]
            dphi[j + count] += last * pulse[j]
        }
        var out = [Float](repeating: 0, count: count)
        var phi = 0.0
        for k in 0..<count {
            out[k] = Float(sin(phi))
            phi += dphi[k + n]
            if phi > 2 * .pi { phi -= 2 * .pi }
        }
        let ramp = n / 8
        for i in 0..<ramp {
            let envelope = Float((1 - cos(2 * Double.pi * Double(i) / Double(2 * ramp))) / 2)
            out[i] *= envelope
            out[count - 1 - i] *= envelope
        }
        return out
    }

    /// The GFSK frequency pulse over three symbols: a unit rectangle of one symbol convolved with a
    /// Gaussian of bandwidth-time product `bt`.
    static func gaussianPulse(samplesPerSymbol n: Int) -> [Double] {
        let k = Double.pi * (2 / log(2.0)).squareRoot()
        return (0..<(3 * n)).map { i in
            let t = Double(i) / Double(n) - 1.5
            return (erf(k * bt * (t + 0.5)) - erf(k * bt * (t - 0.5))) / 2
        }
    }
}
