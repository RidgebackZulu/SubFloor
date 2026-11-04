import Foundation
import Testing
@testable import Scheduling

/// Frames built by hand: 250 Hz per point over 6900–7000 kHz, noise at −110, one frame a second.
struct WatchDetectorTests {
    private static let low = 6_900_000.0, high = 7_000_000.0, step = 250.0
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A frame with each signal's points (those whose start lies in `[fromKHz, toKHz)`) at `level`.
    private func frame(_ signals: [(fromKHz: Double, toKHz: Double, level: Float)]) -> [Float] {
        let count = Int((Self.high - Self.low) / Self.step)
        var levels = [Float](repeating: -110, count: count)
        for s in signals {
            for k in 0..<count {
                let hz = Self.low + Double(k) * Self.step
                if hz >= s.fromKHz * 1_000 && hz < s.toKHz * 1_000 { levels[k] = s.level }
            }
        }
        return levels
    }

    private func feed(_ d: inout WatchDetector, _ levels: [Float], second: Double) -> [WatchCandidate] {
        d.feed(levels: levels, fromHz: Self.low, binHz: Self.step, at: Self.t0.addingTimeInterval(second))
    }

    private func detector() -> WatchDetector { WatchDetector(lowHz: Self.low, highHz: Self.high) }

    @Test func wideSignalHeldThreeSecondsIsACandidate() {
        var d = detector()
        let on = frame([(6_921, 6_929, -95)])
        // Seen at 0, 1 and 2 s: not yet standing 3 s.
        for s in 0..<3 { #expect(feed(&d, on, second: Double(s)).isEmpty) }
        let found = feed(&d, on, second: 3)
        #expect(found == [WatchCandidate(hz: 6_925_000, widthHz: 8_000, overFloorDb: 15)])
        // Still there a second later: still a candidate.
        #expect(feed(&d, on, second: 4).count == 1)
    }

    @Test func shortBurstIsNot() {
        var d = detector()
        let on = frame([(6_921, 6_929, -95)]), off = frame([])
        #expect(feed(&d, on, second: 0).isEmpty)
        #expect(feed(&d, on, second: 1).isEmpty)
        for s in 2...6 { #expect(feed(&d, off, second: Double(s)).isEmpty) }
        // Back at 7 s: it starts holding again.
        #expect(feed(&d, on, second: 7).isEmpty)
    }

    @Test func bareCarrierIsNot() {
        var d = detector()
        let on = frame([(6_950, 6_950.25, -60)])
        for s in 0...6 { #expect(feed(&d, on, second: Double(s)).isEmpty) }
    }

    @Test func belowTenDbIsNot() {
        var d = detector()
        let on = frame([(6_921, 6_929, -102)])
        for s in 0...6 { #expect(feed(&d, on, second: Double(s)).isEmpty) }
    }

    @Test func edgeGuardIgnoresTheBandEdge() {
        // A peak centred at 6999.0, and a control at 6987.5 that does count.
        var d = detector()
        let near = frame([(6_998.25, 6_999.75, -80), (6_985, 6_990, -95)])
        for s in 0...4 { _ = feed(&d, near, second: Double(s)) }
        #expect(feed(&d, near, second: 5).map(\.hz) == [6_987_500])
        // One bleeding into 7000.0: its centre within the span (6996.5) is outside the guard, but its edge is the span's.
        var e = detector()
        let bleeding = frame([(6_993, 7_000, -80)])
        for s in 0...6 { #expect(feed(&e, bleeding, second: Double(s)).isEmpty) }
    }

    @Test func rejectedSpotIsSkippedUntilItsTime() {
        var d = detector()
        let on = frame([(6_921, 6_929, -95)])
        for s in 0..<3 { _ = feed(&d, on, second: Double(s)) }
        #expect(feed(&d, on, second: 3).count == 1)
        // Rejected near its centre (within `sameSpotHz`) until 6 s.
        d.reject(6_926_000, until: Self.t0.addingTimeInterval(6))
        #expect(feed(&d, on, second: 4).isEmpty)
        #expect(feed(&d, on, second: 5).isEmpty)
        #expect(feed(&d, on, second: 6).map(\.hz) == [6_925_000])
    }

    @Test func twoSignalsGiveTwoCandidatesFirstFoundFirst() {
        var d = detector()
        // The higher one comes on first, the lower a second later.
        let first = frame([(6_960, 6_966, -95)])
        let both = frame([(6_960, 6_966, -95), (6_910, 6_916, -90)])
        _ = feed(&d, first, second: 0)
        for s in 1..<3 { #expect(feed(&d, both, second: Double(s)).isEmpty) }
        #expect(feed(&d, both, second: 3).map(\.hz) == [6_963_000])
        #expect(feed(&d, both, second: 4).map(\.hz) == [6_963_000, 6_913_000])
    }

    @Test func aSpotSeenAgainAfterAGapHoldsAgain() {
        // Frames stop while a station is recorded; a spot seen again afterwards must stand its 3 s again.
        var d = detector()
        let on = frame([(6_921, 6_929, -95)])
        for s in 0...3 { _ = feed(&d, on, second: Double(s)) }
        #expect(feed(&d, on, second: 20).isEmpty)
        #expect(feed(&d, on, second: 22).isEmpty)
        #expect(feed(&d, on, second: 23).count == 1)
    }
}
