import Accelerate
import DSPCore
import Foundation

/// OFDM's carrier spacing from its cyclic prefix: each symbol's prefix repeats its last part, one useful
/// symbol length Tu = 1 / spacing earlier, so the signal correlates with itself at lag Tu (by the prefix's
/// share of the symbol: 0.1 for guard 1/9, 0.2 for 1/4). That correlation is the carrier comb seen from the
/// time side: the spectrum's ripple at the spacing is its Fourier transform.
///
/// |R(τ)| / R(0) is computed for every lag at once (R by FFT, zero-padded so it doesn't wrap), over at most
/// the newest 2¹⁸ samples (128 ms of DAB, 5 s of DRM at 48 kS/s). The peak is searched from 8 / B (past the
/// band-limited signal's own correlation; B the occupied width) to a sixteenth of the samples or 100 ms;
/// its contrast is its height over the median of that range. Tu is interpolated (parabola), and the spacing
/// is the rate / Tu. OFDM puts many carriers in its band (B × Tu ≥ 16), and its prefix repeats once: the
/// correlation at 2 Tu is under half that at Tu, where a periodic signal's isn't.
struct OFDMFeatures {
    static let maxSamples = 1 << 18
    static let maxLagSeconds = 0.1
    static let minCorrelation = 0.03
    static let minContrast = 6.0
    static let minCarriers = 16.0
    static let maxRecurrence = 0.5

    var spacingHz = 0.0
    /// |R(Tu)| / R(0).
    var correlation = 0.0
    /// That over the median across the lags searched.
    var contrast = 0.0
    /// Carriers in the occupied width at the spacing found.
    var carriers = 0.0
    /// |R(2 Tu)| over |R(Tu)|: small for a cyclic prefix (it repeats once), near 1 for a periodic signal
    /// (APT's 2400 Hz subcarrier correlates at every multiple of its period).
    var recurrence = 0.0

    init?(_ z: [DSPComplex], rate: Double, occupiedHz: Double) {
        let samples = z.suffix(Self.maxSamples)
        let n = samples.count
        let first = max(16, Int((8 * rate / max(occupiedHz, 1)).rounded(.up)))
        let last = min(n / 16, Int(Self.maxLagSeconds * rate))
        guard last > first + 16 else { return nil }
        let size = FFT.size(atLeast: n + last + 1)
        var re = [Float](repeating: 0, count: size), im = [Float](repeating: 0, count: size)
        for (k, s) in samples.enumerated() {
            re[k] = s.real
            im[k] = s.imag
        }
        FFT.transform(&re, &im)
        for k in 0..<size {
            re[k] = re[k] * re[k] + im[k] * im[k]
            im[k] = 0
        }
        FFT.transform(&re, &im, inverse: true)
        let zero = Double(re[0])
        guard zero > 0 else { return nil }
        let rho = (0...last).map { Double(re[$0] * re[$0] + im[$0] * im[$0]).squareRoot() / zero }
        let range = first...last
        let peak = range.max { rho[$0] < rho[$1] }!
        let sorted = range.map { rho[$0] }.sorted()
        correlation = rho[peak]
        contrast = correlation / max(sorted[sorted.count / 2], 1e-12)
        guard peak > first, peak < last else { return nil }
        let (a, b, c) = (rho[peak - 1], rho[peak], rho[peak + 1])
        let curvature = a - 2 * b + c
        let shift = curvature < 0 ? min(0.5, max(-0.5, 0.5 * (a - c) / curvature)) : 0
        spacingHz = rate / (Double(peak) + shift)
        carriers = occupiedHz / spacingHz
        if 2 * peak + 1 <= last {
            recurrence = (2 * peak - 1...2 * peak + 1).map { rho[$0] }.max()! / correlation
        }
    }

    /// A cyclic prefix: a correlation peak standing out, at a lag that puts many carriers (16 or more) in
    /// the band, and not repeating at twice the lag.
    var isOFDM: Bool {
        correlation >= Self.minCorrelation && contrast >= Self.minContrast && carriers >= Self.minCarriers
            && recurrence < Self.maxRecurrence
    }
}
