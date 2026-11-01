import Accelerate
import DSPCore
import Foundation

/// A channel's envelope as two levels and the runs between them, shared by `Keying` and `Bursts`: the
/// amplitude at 1 ms steps, smoothed over about 1 / bandwidth, split by Otsu's threshold, then cut into on
/// and off runs with hysteresis (40% / 60% of the way from the off to the on amplitude); runs under a
/// quarter of the median run (at least 3 ms) are noise and are merged into their neighbours. Nil when there
/// are under 200 steps or no split.
struct EnvelopeRuns {
    /// Smoothed amplitude per step.
    var amplitude: [Double]
    var step: Int
    var stepSeconds: Double
    /// Median amplitudes of the two levels.
    var onLevel: Double
    var offLevel: Double
    /// Fraction of the steps on.
    var duty: Double
    /// In steps, in order; the first and last are cut by the capture.
    var runs: [(on: Bool, length: Int)]

    init?(_ power: [Float], rate: Double, bandwidthHz: Double) {
        step = max(1, Int((Keying.stepSeconds * rate).rounded()))
        stepSeconds = Double(step) / rate
        amplitude = EnvelopeFeatures.blockMeans(power, length: step).map { Double($0) }
        guard amplitude.count >= 200 else { return nil }
        // Smooth over ~1/bandwidth (at least 1 step), then to amplitude.
        let reach = max(0, Int((0.5 / max(bandwidthHz, 1) / stepSeconds).rounded()))
        if reach > 0 {
            let prefix = OccupiedWidth.prefixSums(amplitude)
            let count = amplitude.count
            amplitude = amplitude.indices.map { k in
                let lo = max(0, k - reach), hi = min(count - 1, k + reach)
                return (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
            }
        }
        amplitude = amplitude.map { $0.squareRoot() }
        guard let split = Keying.otsu(amplitude) else { return nil }
        let on = amplitude.filter { $0 >= split }.sorted()
        let off = amplitude.filter { $0 < split }.sorted()
        guard !on.isEmpty, !off.isEmpty else { return nil }
        onLevel = on[on.count / 2]
        offLevel = off[off.count / 2]
        duty = Double(on.count) / Double(amplitude.count)

        let high = offLevel + 0.6 * (onLevel - offLevel), low = offLevel + 0.4 * (onLevel - offLevel)
        var runs: [(on: Bool, length: Int)] = []
        var state = amplitude[0] >= split
        var length = 0
        for a in amplitude {
            let next = state ? a >= low : a > high
            if next != state {
                runs.append((state, length))
                state = next
                length = 0
            }
            length += 1
        }
        runs.append((state, length))
        self.runs = Keying.merged(runs, shorterThan: max(3, Keying.median(runs.map(\.length)) / 4))
    }
}

/// Transmissions with silence between them (TDMA slots, packets, FT8's slots), from `EnvelopeRuns`: the
/// envelope must be two-level (off under 35% of on) with an on run and an off run (one switch will do: FT8
/// starting half a second into the capture).
/// - `segments` are the on runs in channel samples, 1 ms in from each end (the ramps), at least 5 ms long:
///   where the FSK, PSK and OFDM measurements look.
/// - `periodSeconds`: from the starts of the on runs (the first run's start is the capture's, not a burst's).
///   With at least 3 starts, each is numbered by the median gap and a least-squares line through them gives
///   the period; nil when they don't fall on one (rms more than 10% of a period off) or the gaps differ by
///   more than a period's tenth from whole multiples of it.
/// - `duty`: the whole on runs' mean length over the period; without a period, the on steps' share.
struct Bursts {
    static let minSegmentSeconds = 0.005

    var segments: [Range<Int>] = []
    var periodSeconds: Double?
    var duty = 0.0

    init?(_ envelope: EnvelopeRuns, sampleCount: Int) {
        guard envelope.offLevel < Keying.maxOffRatio * envelope.onLevel, envelope.runs.count >= 2 else { return nil }
        let step = envelope.step
        var position = 0
        var starts: [Double] = []
        var whole: [Double] = []
        for (i, run) in envelope.runs.enumerated() {
            defer { position += run.length }
            guard run.on else { continue }
            let from = position * step + step, to = min(sampleCount, (position + run.length) * step - step)
            if Double(to - from) >= Self.minSegmentSeconds / envelope.stepSeconds * Double(step) {
                segments.append(from..<to)
            }
            if i > 0 { starts.append(Double(position) * envelope.stepSeconds) }
            if i > 0 && i < envelope.runs.count - 1 { whole.append(Double(run.length) * envelope.stepSeconds) }
        }
        guard !segments.isEmpty else { return nil }
        duty = envelope.duty
        guard starts.count >= 3 else { return }
        let gaps = zip(starts.dropFirst(), starts).map { $0 - $1 }.sorted()
        let typical = gaps[gaps.count / 2]
        guard typical > 0 else { return }
        let numbers = starts.map { (($0 - starts[0]) / typical).rounded() }
        guard zip(starts, numbers).allSatisfy({ abs($0 - starts[0] - $1 * typical) <= 0.1 * typical * max(1, $1) }),
              let fit = FSKFeatures.line(numbers, starts) else { return }
        let rms = (zip(numbers, starts).reduce(0) { sum, pair in
            let error = pair.1 - fit.intercept - fit.slope * pair.0
            return sum + error * error
        } / Double(starts.count)).squareRoot()
        guard fit.slope > 0, rms <= 0.1 * fit.slope else { return }
        periodSeconds = fit.slope
        if !whole.isEmpty { duty = min(1, whole.reduce(0, +) / Double(whole.count) / fit.slope) }
    }
}
