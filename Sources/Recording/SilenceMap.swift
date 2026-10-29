import Foundation

/// The silent stretches of a recording, found from its waveform peaks: what the player skips over.
public struct SilenceMap: Equatable, Sendable {
    /// The shortest silence worth skipping, in seconds.
    public static let minimumGap = 0.25
    /// How far before the next sound a skip lands, in seconds, so the first moment of the sound is not cut.
    public static let landingMargin = 0.2
    /// The least a skip must gain, in seconds: a smaller one is not worth the jump.
    private static let minimumSkip = 0.05

    /// Silent runs in seconds, each ≥ minimumGap, sorted.
    public let runs: [Range<Double>]
    public let duration: Double

    public init(peaks: WaveformPeaks) {
        let perSecond = Double(WaveformPeaks.binsPerSecond)
        let bins = peaks.peaks
        var runs: [Range<Double>] = []
        var index = 0
        while index < bins.count {
            guard bins[index] == 0 else { index += 1; continue }
            let start = index
            while index < bins.count, bins[index] == 0 { index += 1 }
            guard Double(index - start) / perSecond >= Self.minimumGap else { continue }
            let lower = Double(start) / perSecond
            // The last bin may be partial: a run that reaches it ends at the audio's true end.
            let upper = min(Double(index) / perSecond, peaks.duration)
            guard upper > lower else { continue }
            runs.append(lower..<upper)
        }
        self.runs = runs
        self.duration = peaks.duration
    }

    /// Where to skip to from `position`: nil if not in a run or nothing is gained (under 0.05 s); otherwise
    /// `run.upperBound - landingMargin`, or `duration` when the run reaches the end of the recording.
    public func skipTarget(from position: Double) -> Double? {
        guard let run = runs.first(where: { $0.contains(position) }) else { return nil }
        let target = run.upperBound >= duration ? duration : run.upperBound - Self.landingMargin
        return target - position >= Self.minimumSkip ? target : nil
    }
}
