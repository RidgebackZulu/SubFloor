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

@Test func aPartialLastBinEndsTheRunAtTheTrueEnd() {
    // 1.505 s: 100 loud bins, then 51 silent bins, the last of which holds only 240 frames (5 ms).
    let bins = [UInt8](repeating: 255, count: 100) + [UInt8](repeating: 0, count: 51)
    let map = SilenceMap(peaks: WaveformPeaks(sampleRate: 48_000, frames: 150 * 480 + 240, peaks: bins))
    #expect(near(map.duration, 1.505))
    #expect(map.runs.count == 1)
    #expect(map.runs.last?.upperBound == map.duration)   // clamped: the full bin would overrun to 1.51
    #expect(map.runs.last!.upperBound < 151.0 / 100)
    #expect(near(map.skipTarget(from: 1.2), map.duration))
}

@Test func aRunOfExactlyAQuarterSecondIsKept() {
    let map = SilenceMap(peaks: peaks((100, true), (25, false), (100, true)))
    #expect(map.runs == [1.0..<1.25])
}

@Test func aRunOfTwentyFourBinsIsDropped() {
    let map = SilenceMap(peaks: peaks((100, true), (24, false), (100, true)))
    #expect(map.runs.isEmpty)
}

@Test func aPositionAtARunsEndIsOutsideIt() {
    let map = SilenceMap(peaks: peaks((100, true), (200, false), (100, true)))   // silent 1.0..<3.0
    #expect(near(map.skipTarget(from: 3.0), nil))
}

@Test func emptyPeaksHaveNoRuns() {
    let map = SilenceMap(peaks: WaveformPeaks(sampleRate: 48_000, frames: 0, peaks: []))
    #expect(map.runs.isEmpty)
    #expect(map.duration == 0)
    #expect(near(map.skipTarget(from: 0), nil))
}

@Test func aGainOfExactlyFiveHundredthsIsKept() {
    // 0.5 s loud, then 0.55 s silent: the run reaches the end at 1.05 s, so from 1.0 the gain is 0.05.
    let map = SilenceMap(peaks: peaks((50, true), (55, false)))
    #expect(near(map.skipTarget(from: 1.0), 1.05))
    #expect(near(map.skipTarget(from: 1.01), nil))   // 0.04 s gained: not worth the jump
}
