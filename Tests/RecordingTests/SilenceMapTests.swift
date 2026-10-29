import Foundation
import Testing
@testable import Recording

/// Peaks for consecutive segments of 10 ms bins, each `loud` (full scale) or silent (0).
private func peaks(_ segments: (count: Int, loud: Bool)...) -> WaveformPeaks {
    let bins = segments.flatMap { Array(repeating: $0.loud ? UInt8(255) : UInt8(0), count: $0.count) }
    return WaveformPeaks(sampleRate: 48_000, frames: bins.count * 480, peaks: bins)   // 480 frames per 10 ms bin
}

/// Whether two optional times agree: sums of 0.01 s are not exact, so they are compared with a tolerance.
private func near(_ actual: Double?, _ expected: Double?) -> Bool {
    guard let actual, let expected else { return actual == nil && expected == nil }
    return abs(actual - expected) < 1e-9
}

@Test func findsRunsAtLeastAQuarterSecond() {
    let map = SilenceMap(peaks: peaks((100, true), (30, false), (50, true), (20, false), (100, true)))
    #expect(map.runs == [1.0..<1.3])   // the 0.2 s gap is not a run
}

@Test func skipTargetLandsBeforeTheAudio() {
    let map = SilenceMap(peaks: peaks((100, true), (200, false), (100, true)))   // silent 1.0..<3.0 of 4.0 s
    #expect(near(map.skipTarget(from: 1.0), 2.8))
    #expect(near(map.skipTarget(from: 2.0), 2.8))
    #expect(near(map.skipTarget(from: 2.78), nil))   // only 0.02 s would be gained
    #expect(near(map.skipTarget(from: 0.5), nil))    // not in a run
}

@Test func trailingSilenceSkipsToTheEnd() {
    let map = SilenceMap(peaks: peaks((100, true), (200, false)))   // 1 s loud, then 2 s silent
    #expect(near(map.skipTarget(from: 1.5), 3.0))
}

@Test func allSilentAndNeverSilent() {
    let silent = SilenceMap(peaks: peaks((200, false)))
    #expect(silent.runs == [0.0..<2.0])
    #expect(near(silent.skipTarget(from: 0), 2.0))

    let loud = SilenceMap(peaks: peaks((100, true)))
    #expect(loud.runs.isEmpty)
    #expect(near(loud.skipTarget(from: 0), nil))
    #expect(near(loud.skipTarget(from: 0.5), nil))
}
