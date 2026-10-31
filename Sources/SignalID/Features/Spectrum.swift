import Accelerate
import DSPCore
import Foundation

/// Signal ID's one definition of occupied bandwidth, shared by the synthesiser's ground truth
/// (`SignalSynth.occupiedBandwidthHz(for:)`) and the measurer.
enum OccupiedWidth {
    /// The fixed point B = span{ bins ≥ ΣP · binHz / (100 B) } of a linear power spectrum: the width whose band
    /// edges are where the density falls to −20 dB of the signal's mean density over that width. Levels are
    /// averaged over ±1% of B (at least ±1 bin), so the answer doesn't hang on the resolution or on single
    /// bins; the edges are the outermost bins at or above the threshold, so gaps inside count. Iterated from
    /// `start` (Hz). `power` holds only the signal: the measurer subtracts the noise first (bins may then be
    /// slightly negative). `bins` is nil when no bin reaches the threshold (`widthHz` is then the last iterate).
    ///
    /// `noiseSigma` is the standard deviation of a single bin's leftover noise (0 for a noise-free spectrum).
    /// Where the −20 dB level lies under the noise's own scatter it can't be seen, so the threshold is
    /// raised to 3 × that scatter averaged over the ±1% (taken as half as many independent bins, since
    /// neighbouring bins share leakage): at low SNR the width is the part that stands out of the noise.
    static func fixedPoint(_ power: [Double], binHz: Double, start: Double,
                           noiseSigma: Double = 0) -> (widthHz: Double, bins: ClosedRange<Int>?) {
        let prefix = prefixSums(power)
        let total = prefix[power.count]
        var b = start
        var found: ClosedRange<Int>?
        for _ in 0..<40 {
            let reach = max(1, Int((0.01 * b / binHz).rounded()))
            let floor = 3 * noiseSigma * (2 / Double(2 * reach + 1)).squareRoot()
            guard let span = span(prefix, reach: reach, threshold: max(total * binHz / (100 * b), floor))
            else { return (b, nil) }
            found = span
            let next = Double(span.count) * binHz
            if abs(next - b) < binHz / 2 { return (next, span) }
            b = next
        }
        return (b, found)
    }

    /// The outermost bins whose level, averaged over ±`reach` bins, is at or above `threshold`.
    static func span(_ prefix: [Double], reach: Int, threshold: Double) -> ClosedRange<Int>? {
        let n = prefix.count - 1
        func level(_ k: Int) -> Double {
            let lo = max(0, k - reach), hi = min(n - 1, k + reach)
            return (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        }
        guard let lo = (0..<n).first(where: { level($0) >= threshold }),
              let hi = (0..<n).last(where: { level($0) >= threshold }) else { return nil }
        return lo...hi
    }

    static func prefixSums(_ p: [Double]) -> [Double] {
        var prefix = [Double](repeating: 0, count: p.count + 1)
        for k in p.indices { prefix[k + 1] = prefix[k] + p[k] }
        return prefix
    }
}

/// An averaged power spectrum (linear) of complex baseband, cut to the band the channel filter passes, with
/// its noise level per bin.
///
/// Frames are Blackman-Harris, 75% overlapped, which leaves about half as many independent ones: a noise-only
/// bin's relative standard deviation (`spread`) is √(1.93 / frames).
struct SpectrumView {
    /// Equivalent noise bandwidth of the 4-term Blackman-Harris window, in bins.
    static let enbw = 2.0044
    let power: [Double]
    let binHz: Double
    /// Frequency of bin 0, relative to the baseband's 0 Hz.
    let firstHz: Double
    let spread: Double
    private(set) var noise = 0.0

    /// `binHz` is a target: the FFT size is the power of two nearest rate / binHz (at least 64).
    init(_ samples: [DSPComplex], rate: Double, binHz target: Double, usableHz: Double, maxFrames: Int = 1024) {
        var size = 64
        while size < 1 << 20 && Double(size) * target < rate / 1.414 { size *= 2 }
        let hop = size / 4
        let full = PowerSpectrum.averagePower(samples, size: size, maxFrames: maxFrames, hop: hop)
        let frames = max(1, min(maxFrames, (samples.count - size) / hop + 1))
        let bin = rate / Double(size)
        let half = min(size / 2 - 1, Int(usableHz / 2 / bin))
        power = full[(size / 2 - half)...(size / 2 + half)].map { Double($0) }
        binHz = bin
        firstHz = -Double(half) * bin
        spread = (1.93 / Double(frames)).squareRoot()
    }

    var count: Int { power.count }
    func bin(_ hz: Double) -> Int { min(count - 1, max(0, Int(((hz - firstHz) / binHz).rounded()))) }
    func hz(_ bin: Double) -> Double { firstHz + bin * binHz }

    /// Sets the noise level: the mean of the bins outside `excluding` that lie under 3 × their median (so
    /// other signals in the band don't lift it). With no exclusion yet (the signal's extent unknown), from
    /// the 20th percentile of all the bins instead, which stays on the noise while signals fill up to
    /// about 70% of the band: the percentile of a noise bin is noise × (1 − 0.84 spread).
    mutating func estimateNoise(excluding: ClosedRange<Int>?) {
        guard let excluding else {
            let sorted = power.sorted()
            noise = max(sorted[sorted.count / 5] / max(1 - 0.8416 * spread, 0.2), 1e-30)
            return
        }
        var values = power.indices.filter { !excluding.contains($0) }.map { power[$0] }
        if values.count < 16 { values = power }
        values.sort()
        let median = values[values.count / 2]
        let kept = values.filter { $0 <= 3 * median }
        noise = max(kept.isEmpty ? median : kept.reduce(0, +) / Double(kept.count), 1e-30)
    }

    /// Power over the noise, as a multiple of the noise (0 = noise only).
    func excess(_ k: Int) -> Double { power[k] / noise - 1 }

    /// `excess` averaged over ±`reach` bins.
    func smoothedExcess(reach: Int) -> [Double] {
        let e = power.map { $0 / noise - 1 }
        let prefix = OccupiedWidth.prefixSums(e)
        return e.indices.map { k in
            let lo = max(0, k - reach), hi = min(count - 1, k + reach)
            return (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        }
    }

    /// The noise-subtracted power of `bins`.
    func signal(_ bins: ClosedRange<Int>) -> [Double] { bins.map { power[$0] - noise } }
}
