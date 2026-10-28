import Foundation
import Testing
@testable import Recording

/// Rate 1,000 frames/s, so a frame is a millisecond and the numbers read as times.
private func feed(_ steps: [(seconds: Double, open: Bool)], timing: AutoRecordTiming = .init()) -> [AutoRecordTrigger.Event] {
    var trigger = AutoRecordTrigger(sampleRate: 1_000, timing: timing)
    var events: [AutoRecordTrigger.Event] = []
    var head = 0
    trigger.advance(to: head, gateOpen: false, into: &events)   // the baseline
    for step in steps {
        for _ in 0..<Int((step.seconds * 100).rounded()) {      // 10-frame blocks
            head += 10
            trigger.advance(to: head, gateOpen: step.open, into: &events)
        }
    }
    return events
}

private func isStart(_ e: AutoRecordTrigger.Event) -> Bool { if case .start = e { true } else { false } }
private func isPop(_ e: AutoRecordTrigger.Event) -> Bool { if case .pop = e { true } else { false } }
private func isSilence(_ e: AutoRecordTrigger.Event) -> Bool { if case .silence = e { true } else { false } }

@Suite struct AutoRecordTriggerTests {
    @Test func popsShorterThanStartAfterMakeNoRecording() {
        let e = feed([(1, false), (0.3, true), (5, false)])
        #expect(e == [.pop(atFrame: 1_000, frames: 300)])
    }

    @Test func aPopReportsItsSpanIncludingBridgedGaps() {
        let e = feed([(0.5, false), (0.3, true), (1.0, false), (0.3, true), (5, false)])
        #expect(e == [.pop(atFrame: 500, frames: 1_600)])
    }

    @Test func speechWithSyllableGapsStartsHalfASecondBeforeTheFirstWord() {
        let e = feed([(10, false)] + Array(repeating: [(0.4, true), (0.2, false)], count: 6).flatMap { $0 })
        #expect(e.first == .start(atFrame: 9_500))
        #expect(!e.contains(where: isPop))
    }

    @Test func gapsLongerThanTheBridgeResetTheCount() {
        let e = feed([(0.5, false), (1.5, true), (1.6, false), (1.5, true), (5, false)])
        #expect(e == [.pop(atFrame: 500, frames: 1_500), .pop(atFrame: 3_600, frames: 1_500)])
    }

    @Test func aBriefReopenWithinStopAfterKeepsOneRecording() {
        let e = feed([(1, false), (5, true), (20, false), (0.1, true), (40, false)])
        #expect(e.filter(isStart) == [.start(atFrame: 500)])
        #expect(e.last == .stop(atFrame: 28_100))   // last open ends at 26_100, + 2 s tail
    }

    @Test func gapsUpToKeepGapsUpToPlayThrough() {
        let e = feed([(1, false), (5, true), (8, false), (2, true), (40, false)])   // an 8 s gap, the default
        #expect(!e.contains(where: isSilence))
        #expect(e.filter(isStart).count == 1)
    }

    @Test func longerGapsAreSilencedBetweenTheTailAndTheLead() {
        let e = feed([(1, false), (5, true), (20, false), (2, true), (40, false)])
        // Open until 6_000, shut 20 s, open again from 26_000: 2 s of tail and 0.5 s of lead stay as heard.
        #expect(e.filter(isSilence) == [.silence(fromFrame: 8_000, toFrame: 25_500)])
        let silence = e.firstIndex(where: isSilence)!
        let commitPast = e.firstIndex { if case .commit(let f) = $0 { f > 8_000 } else { false } }!
        #expect(silence < commitPast, "silenced before the writer may reach it")
    }

    @Test func keepGapsUpToIsConfigurable() {
        let e = feed([(1, false), (5, true), (6, false), (2, true), (40, false)], timing: .init(keepGapsUpTo: 3))
        #expect(e.filter(isSilence) == [.silence(fromFrame: 8_000, toFrame: 11_500)])
    }

    @Test func aGapJustOverTheLimitWithNoRoomBetweenTailAndLeadSilencesNothing() {
        let e = feed([(1, false), (5, true), (2.3, false), (2, true), (40, false)], timing: .init(keepGapsUpTo: 2))
        #expect(!e.contains(where: isSilence))
    }

    @Test func commitsNeverPassTheStopAndEndOnIt() {
        let e = feed([(1, false), (5, true), (40, false)])
        let commits = e.compactMap { if case .commit(let f) = $0 { f } else { nil } }
        #expect(commits.allSatisfy { $0 <= 8_000 } && commits.last == 8_000 && e.last == .stop(atFrame: 8_000))
    }

    @Test func cutWhileOpenStopsAtTheHead() {
        var t = AutoRecordTrigger(sampleRate: 1_000, timing: .init())
        var e: [AutoRecordTrigger.Event] = []
        var head = 0
        t.advance(to: 0, gateOpen: false, into: &e)
        for (open, blocks) in [(false, 100), (true, 500)] {   // 1 s shut, 5 s open
            for _ in 0..<blocks { head += 10; t.advance(to: head, gateOpen: open, into: &e) }
        }
        #expect(t.isRecording)
        t.cut(into: &e)
        #expect(e.last == .stop(atFrame: 6_000))
        #expect(!t.isRecording)
    }

    @Test func cutAfterTheGateShutStopsAfterTheTail() {
        var t = AutoRecordTrigger(sampleRate: 1_000, timing: .init())
        var e: [AutoRecordTrigger.Event] = []
        var head = 0
        t.advance(to: 0, gateOpen: false, into: &e)
        for (open, blocks) in [(true, 300), (false, 50)] {   // 3 s open, 0.5 s shut
            for _ in 0..<blocks { head += 10; t.advance(to: head, gateOpen: open, into: &e) }
        }
        t.cut(into: &e)
        #expect(e.last == .stop(atFrame: 3_500))   // the head, not last open + tail (5_000)
    }

    @Test func cutDuringAnUndecidedRunDiscardsIt() {
        var t = AutoRecordTrigger(sampleRate: 1_000, timing: .init())
        var e: [AutoRecordTrigger.Event] = []
        var head = 0
        t.advance(to: 0, gateOpen: false, into: &e)
        for _ in 0..<100 { head += 10; t.advance(to: head, gateOpen: true, into: &e) }
        t.cut(into: &e)
        #expect(e.isEmpty)
        // And it is idle afterwards: shutting the gate raises no late pop.
        for _ in 0..<400 { head += 10; t.advance(to: head, gateOpen: false, into: &e) }
        #expect(e.isEmpty)
    }

    @Test func aShrinkingHeadResetsSilently() {
        var t = AutoRecordTrigger(sampleRate: 1_000, timing: .init())
        var e: [AutoRecordTrigger.Event] = []
        var head = 0
        t.advance(to: 0, gateOpen: false, into: &e)
        for _ in 0..<300 { head += 10; t.advance(to: head, gateOpen: true, into: &e) }
        #expect(t.isRecording)
        e = []
        t.advance(to: 0, gateOpen: true, into: &e)
        #expect(e.isEmpty && !t.isRecording)
    }

    @Test func autoTurnedOnMidSignalStartsAfterStartAfter() {
        var t = AutoRecordTrigger(sampleRate: 1_000, timing: .init()); var e: [AutoRecordTrigger.Event] = []
        t.advance(to: 50_000, gateOpen: true, into: &e)          // baseline: Auto just turned on
        var head = 50_000
        while e.isEmpty { head += 10; t.advance(to: head, gateOpen: true, into: &e) }
        #expect(head == 52_000 && e.first == .start(atFrame: 49_500))
    }

    @Test func changingTimingAppliesFromTheNextBlock() {
        var t = AutoRecordTrigger(sampleRate: 1_000, timing: .init())
        var e: [AutoRecordTrigger.Event] = []
        var head = 0
        t.advance(to: 0, gateOpen: false, into: &e)
        for _ in 0..<100 { head += 10; t.advance(to: head, gateOpen: true, into: &e) }   // 1 s of 2 s
        #expect(e.isEmpty)
        t.timing.startAfter = 1.0
        head += 10; t.advance(to: head, gateOpen: true, into: &e)
        #expect(e.first == .start(atFrame: 0))   // run began at 0; 0 - lead clamps to 0
    }

    @Test func timingNormalizesToTheAllowedValues() {
        #expect(AutoRecordTiming(startAfter: 0.1, stopAfter: 40).normalized() == .init(startAfter: 0.5, stopAfter: 45))
        #expect(AutoRecordTiming(startAfter: 20, stopAfter: 7).normalized() == .init(startAfter: 10, stopAfter: 5))
        #expect(AutoRecordTiming().normalized() == AutoRecordTiming())
        #expect(AutoRecordTiming().keepGapsUpTo == 8)
        #expect(AutoRecordTiming(keepGapsUpTo: 7).normalized().keepGapsUpTo == 8)
        #expect(AutoRecordTiming(keepGapsUpTo: 0).normalized().keepGapsUpTo == 1)
        #expect(AutoRecordTiming.maxHoldbackSeconds == 612)
    }

    @Test func timingDecodesMissingFieldsAsDefaultsAndNormalizes() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(AutoRecordTiming.self, from: Data("{}".utf8)) == AutoRecordTiming())
        #expect(try decoder.decode(AutoRecordTiming.self, from: Data(#"{"stopAfter":60,"later":true}"#.utf8))
                == AutoRecordTiming(startAfter: 2, stopAfter: 60))
        #expect(try decoder.decode(AutoRecordTiming.self, from: Data(#"{"startAfter":0.1,"stopAfter":40}"#.utf8))
                == AutoRecordTiming(startAfter: 0.5, stopAfter: 45))
        #expect(try decoder.decode(AutoRecordTiming.self, from: Data(#"{"keepGapsUpTo":3}"#.utf8))
                == AutoRecordTiming(keepGapsUpTo: 3))
        let timing = AutoRecordTiming(startAfter: 3, stopAfter: 120, keepGapsUpTo: 15)
        #expect(try decoder.decode(AutoRecordTiming.self, from: JSONEncoder().encode(timing)) == timing)
    }
}
