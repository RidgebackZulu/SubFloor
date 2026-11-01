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
    static let minPlateau = 0.05

    var spacingHz = 0.0
    /// |R(Tu)| / R(0).
    var correlation = 0.0
    /// That over the median across the lags searched.
    var contrast = 0.0
    /// Tu in samples.
    var usefulSamples = 0.0
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
        // Scaled to unit power: |X|² of a large input over 2¹⁸ samples would lose the lags in Float.
        let power = samples.reduce(0.0) { $0 + Double($1.real * $1.real + $1.imag * $1.imag) } / Double(max(n, 1))
        guard power > 0 else { return nil }
        let scale = Float(1 / power.squareRoot())
        for (k, s) in samples.enumerated() {
            re[k] = s.real * scale
            im[k] = s.imag * scale
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
        usefulSamples = Double(peak) + shift
        spacingHz = rate / usefulSamples
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

    /// The in-band SNR from the cyclic prefix, for when no noise can be seen beside the signal (it fills the
    /// view): p[k] = z[k + Tu] · z*[k] averages to the signal's power during each prefix and to 0 elsewhere, so
    /// folded over the symbol period Ts it shows where the prefixes lie. There the signal repeats exactly, and
    /// z[k + Tu] − z[k] is noise alone: its power is 2N, the least of the folded |z[k + Tu] − z[k]|²; the SNR is
    /// (E|z|² − N) / N. Ts is the line of p's spectrum between rate / 1.5 Tu and rate / 1.01 Tu (prefixes of up
    /// to half a symbol), refined to the tallest plateau within ±½ bin; the fold has 64 phase bins, smoothed
    /// over 3. Nil when the plateau doesn't stand out (over 1 in 20 of the power).
    func prefixSNR(_ z: [DSPComplex], rate: Double) -> Double? {
        let samples = Array(z.suffix(Self.maxSamples))
        let lag = Int(usefulSamples.rounded())
        let n = samples.count - lag
        guard lag > 0, n > 16 * lag else { return nil }
        var re = [Float](repeating: 0, count: FFT.size(atLeast: n)), im = re
        var power = 0.0
        for k in 0..<n {
            let a = samples[k + lag], b = samples[k]
            re[k] = a.real * b.real + a.imag * b.imag
            im[k] = a.imag * b.real - a.real * b.imag
            power += Double(b.real * b.real + b.imag * b.imag)
        }
        power /= Double(n)
        let product = (re: Array(re[0..<n]), im: Array(im[0..<n]))
        FFT.transform(&re, &im)
        let binHz = rate / Double(re.count)
        let lo = Int((rate / (1.5 * usefulSamples) / binHz).rounded(.up))
        let hi = Int((rate / (1.01 * usefulSamples) / binHz).rounded(.down))
        guard lo < hi else { return nil }
        var top = lo
        var strongest: Float = 0
        for k in lo...hi {
            let p: Float = re[k] * re[k] + im[k] * im[k]
            if p > strongest { strongest = p; top = k }
        }
        // The period to a fraction of a bin (the fold spans 200 symbols of DAB: a 0.25% error smears it by half
        // a symbol): the tallest plateau within ±½ bin of the line.
        let bins = 64
        func smoothed(_ x: [Double]) -> [Double] {
            var out = [Double](repeating: 0, count: bins)
            for b in 0..<bins {
                let sum: Double = x[(b + bins - 1) % bins] + x[b] + x[(b + 1) % bins]
                out[b] = sum / 3
            }
            return out
        }
        func fold(_ symbol: Double) -> (plateau: Double, difference: [Double]) {
            var sumR = [Double](repeating: 0, count: bins), sumI = sumR, sumD = sumR, count = sumR
            for k in 0..<n {
                let phase = (Double(k) / symbol).truncatingRemainder(dividingBy: 1)
                let b = min(bins - 1, Int(phase * Double(bins)))
                sumR[b] += Double(product.re[k])
                sumI[b] += Double(product.im[k])
                let dr = samples[k + lag].real - samples[k].real, di = samples[k + lag].imag - samples[k].imag
                sumD[b] += Double(dr * dr + di * di)
                count[b] += 1
            }
            var level = [Double](repeating: 0, count: bins), difference = level
            for b in 0..<bins {
                let magnitude: Double = (sumR[b] * sumR[b] + sumI[b] * sumI[b]).squareRoot()
                level[b] = magnitude / max(count[b], 1)
                difference[b] = sumD[b] / max(count[b], 1)
            }
            return (smoothed(level).max() ?? 0, smoothed(difference))
        }
        let best = (-10...10).map { fold(rate / ((Double(top) + Double($0) / 20) * binHz)) }
            .max { $0.plateau < $1.plateau }!
        guard best.plateau > Self.minPlateau * power else { return nil }
        // Within the prefix the signal repeats exactly, so z[k + Tu] − z[k] is noise alone, twice over.
        let noise = (best.difference.min() ?? 0) / 2
        guard noise > 0, power > noise else { return nil }
        return 10 * log10((power - noise) / noise)
    }
}
