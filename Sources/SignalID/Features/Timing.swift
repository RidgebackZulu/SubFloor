import Accelerate
import Foundation

/// A period in a demodulated signal from 0.2 to 2 s: HF fax lines (the image repeats line to line, each line
/// opening with a white margin) and a time signal's second ticks (its tone silenced around each tick).
///
/// The series is the signal in 10 ms blocks: for AM, each block's envelope variance (the audio's power, where the
/// ticks and their silence show); otherwise each block's mean instantaneous frequency (an FM fax's image). Its
/// normalised autocorrelation r(τ) is summed along each candidate period's multiples, C(P) = mean r(kP) for
/// kP up to half the read (a comb in lag, fine in P however coarse the blocks, and as sensitive to a short tick
/// as to a whole line). The period is the shortest P at a local maximum of C within 80% of the highest (not a
/// multiple of it), where C stands `minCorrelation` high and `minProminence` over the median of C across the
/// range (slowly varying programme or speech correlates at every lag alike, with no peak). Needs 6 s.
enum ModulationPeriod {
    static let blockSeconds = 0.01
    static let range = 0.2...2.0
    /// The grid of candidate periods.
    static let stepSeconds = 0.0005
    static let minSeconds = 6.0
    static let minCorrelation = 0.2
    static let minProminence = 0.15
    static let fundamentalShare = 0.8

    /// The period in seconds, or nil when there is none (or the read is shorter than `minSeconds`).
    static func find(_ z: [DSPComplex], rate: Double, am: Bool) -> Double? {
        let block = Int((blockSeconds * rate).rounded())
        guard block >= 4, Double(z.count) / rate >= minSeconds else { return nil }
        let series = am ? envelopeVariance(z, block: block) : meanFrequency(z, rate: rate, block: block)
        let r = autocorrelation(series)
        let maxLag = series.count / 2
        let periods = stride(from: range.lowerBound, through: range.upperBound, by: stepSeconds).map { $0 }
        let comb = periods.map { p -> Double in
            let lag = p / blockSeconds
            let count = Int(Double(maxLag) / lag)
            guard count >= 2 else { return 0 }
            var sum = 0.0
            for k in 1...count {
                // Linear interpolation between the blocks' lags.
                let x = Double(k) * lag
                let i = Int(x), f = x - Double(i)
                sum += (1 - f) * r[i] + f * r[min(i + 1, r.count - 1)]
            }
            return sum / Double(count)
        }
        let median = comb.sorted()[comb.count / 2]
        guard let highest = comb.max(), highest >= minCorrelation, highest - median >= minProminence else { return nil }
        for i in comb.indices where comb[i] >= fundamentalShare * highest {
            let left = i > 0 ? comb[i - 1] : -.infinity, right = i + 1 < comb.count ? comb[i + 1] : -.infinity
            guard comb[i] >= left && comb[i] >= right else { continue }
            return periods[i]
        }
        return nil
    }

    /// Each block's variance of |z|.
    static func envelopeVariance(_ z: [DSPComplex], block: Int) -> [Double] {
        var magnitude = [Float](repeating: 0, count: z.count)
        z.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: Float.self, capacity: 2 * z.count) { f in
                var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: f),
                                            imagp: UnsafeMutablePointer(mutating: f + 1))
                vDSP_zvabs(&split, 2, &magnitude, 1, vDSP_Length(z.count))
            }
        }
        return (0..<(z.count / block)).map { b in
            var mean: Float = 0, square: Float = 0
            magnitude.withUnsafeBufferPointer { m in
                vDSP_meanv(m.baseAddress! + b * block, 1, &mean, vDSP_Length(block))
                vDSP_measqv(m.baseAddress! + b * block, 1, &square, vDSP_Length(block))
            }
            return Double(square - mean * mean)
        }
    }

    /// Each block's mean instantaneous frequency.
    static func meanFrequency(_ z: [DSPComplex], rate: Double, block: Int) -> [Double] {
        let f = FrequencyFeatures.discriminator(z, rate: rate)
        return EnvelopeFeatures.blockMeans(f, length: block).map(Double.init)
    }

    /// r(τ) / r(0) of the mean-removed series for τ = 0…n − 1, by FFT (zero-padded: no wrap-around).
    static func autocorrelation(_ x: [Double]) -> [Double] {
        let n = x.count
        guard n > 1 else { return [1] }
        let mean = x.reduce(0, +) / Double(n)
        let size = FFT.size(atLeast: 2 * n)
        var re = [Float](repeating: 0, count: size), im = [Float](repeating: 0, count: size)
        for i in 0..<n { re[i] = Float(x[i] - mean) }
        FFT.transform(&re, &im)
        for i in 0..<size {
            re[i] = re[i] * re[i] + im[i] * im[i]
            im[i] = 0
        }
        FFT.transform(&re, &im, inverse: true)
        let zero = max(Double(re[0]), 1e-30)
        // Unbiased: each lag's sum over the n − τ pairs it has.
        return (0..<n).map { tau in Double(re[tau]) / zero * Double(n) / Double(n - tau) }
    }
}
