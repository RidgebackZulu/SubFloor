import Foundation
import Synchronization

extension SignalSynth {
    /// The occupied bandwidth of `spec`, measured on a noise-free render and cached per spec: the width B
    /// whose band edges are where the averaged power spectral density falls to 1/100 (−20 dB) of the
    /// signal's mean density over B, i.e. to P / (100 B) for total power P.
    ///
    /// That is the −20 dB width referred to the in-band mean rather than to the highest bin, because the
    /// highest bin of a spectrum with lines (AM's carrier, CW, integer-index FSK) depends on the FFT
    /// resolution; for a flat spectrum the two agree. It is also exactly what `Extent.find` recovers at
    /// 20 dB SNR, where the noise density is P / (100 B) and the extent stops where the signal meets it.
    ///
    /// The edges are the outermost bins at or above the threshold (levels averaged over ±1% of B), so gaps
    /// inside (AM's low-cut, FSK between tones) count. Found by fixed-point iteration from twice the nominal
    /// width. The render: a sample rate of 8 × the nominal width (4 × above 125 kHz, 1.5 × above 400 kHz),
    /// again at that multiple of the width found when it is over a quarter of the rate; 1024-bin
    /// Blackman-Harris frames over 2 s (at least 256 frames, at most 10⁶ samples); a fixed seed. Impairments
    /// are not included. A carrier has no width of its own: it is given 10 Hz; noise 0.
    public static func occupiedBandwidthHz(for spec: SynthSpec) -> Double {
        if let cached = OccupiedBandwidth.cache.withLock({ $0[spec] }) { return cached }
        let value = OccupiedBandwidth.measure(spec)
        OccupiedBandwidth.cache.withLock { $0[spec] = value }
        return value
    }
}

enum OccupiedBandwidth {
    static let cache = Mutex<[SynthSpec: Double]>([:])
    static let size = 1024
    static let seed: UInt64 = 0x0CC0_BA4D

    static func measure(_ spec: SynthSpec) -> Double {
        switch spec {
        case .noise: return 0
        case .carrier: return 10
        default: break
        }
        var guess = spec.nominalBandwidthHz
        var found = guess
        // Rendered again, wider, if the width comes out over a quarter of the render's rate.
        for _ in 0..<3 {
            let rate = guess <= 125_000 ? 8 * guess : guess <= 400_000 ? 4 * guess : 1.5 * guess
            let binHz = rate / Double(size)
            let seconds = min(max(256 * Double(size) / rate, 2), 1_000_000 / rate)
            let iq = SignalSynth.render(spec, sampleRate: rate, seconds: seconds, seed: seed)
            found = width(PowerSpectrum.average(iq, size: size, maxFrames: 4096), binHz: binHz, start: 2 * guess)
            if found <= rate / 4 || guess > 400_000 { break }
            guess = found
        }
        return found
    }

    /// The occupied width of a power spectrum in dB (see `OccupiedWidth.fixedPoint`).
    static func width(_ spectrumDb: [Float], binHz: Double, start: Double) -> Double {
        OccupiedWidth.fixedPoint(spectrumDb.map { pow(10, Double($0) / 10) }, binHz: binHz, start: start).widthHz
    }
}
