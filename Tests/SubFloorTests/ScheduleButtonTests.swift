import Foundation
import Scheduling
import Testing
@testable import SubFloor

/// The Schedule button's look, labels and click actions, as a pure value (the view only draws it).
struct ScheduleButtonTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var item: TickerItem { TickerItem(name: "Voice of Korea", start: start, frequencyHz: 9_435_000, mode: "am") }

    @Test func offLooksAndActs() {
        let m = ScheduleButtonModel(state: .off(waiting: 4), zone: utc)
        #expect(m.look == .off)
        #expect(m.leftLabel == "Schedule")
        #expect(m.tickerText == "off · 4 schedules waiting")
        #expect(m.leftAction == .turnOn)
        #expect(m.tickerAction == .none)
    }

    @Test func soonPulsesAndTickerStartsEarly() {
        let later = ScheduleButtonModel(state: .later([item]), zone: utc)
        #expect(later.look == .later)
        #expect(later.leftLabel == "Schedule")
        #expect(later.leftAction == .turnOff)
        #expect(later.tickerAction == .none)

        let soon = ScheduleButtonModel(state: .soon(item, secondsLeft: 272), zone: utc)
        #expect(soon.look == .soon)
        #expect(soon.look.pulses)
        #expect(!later.look.pulses)
        #expect(soon.leftLabel == "Schedule")
        #expect(soon.tickerText == "in 4:32 · Voice of Korea · 9435 kHz AM · click to start now")
        #expect(soon.leftAction == .turnOff)
        #expect(soon.tickerAction == .startEarly)
    }

    @Test func recordingShowsElapsedAndStopsTheRun() {
        let m = ScheduleButtonModel(state: .recording(item, elapsed: 724, marginDb: 9, until: start), zone: utc)
        #expect(m.look == .recording)
        #expect(m.leftLabel == "12:04")
        #expect(m.leftAction == .stopRun)
        #expect(m.tickerAction == .none)
        let long = ScheduleButtonModel(state: .recording(item, elapsed: 3_725, marginDb: 9, until: start), zone: utc)
        #expect(long.leftLabel == "1:02:05")
    }

    @Test func watchingShowsTheEye() {
        let watch = TickerItem(name: "pirates", start: start, lowHz: 6_900_000, highHz: 7_000_000)
        let m = ScheduleButtonModel(state: .watching(watch, caught: 2, until: start), zone: utc)
        #expect(m.look == .watching)
        #expect(m.leftLabel == "Watching")
        #expect(m.look.symbol == "eye")
        #expect(m.leftAction == .stopRun)
        #expect(m.tickerAction == .none)
        #expect(m.tickerText.contains("2 caught tonight"))
    }

    @Test func accessibilityLabels() {
        #expect(ScheduleButtonModel(state: .off(waiting: 0), zone: utc).accessibilityLabel
                == "Scheduler off: click to turn it on")
        #expect(ScheduleButtonModel(state: .later([]), zone: utc).accessibilityLabel
                == "Scheduler on: click to turn it off")
        #expect(ScheduleButtonModel(state: .soon(item, secondsLeft: 60), zone: utc).accessibilityLabel
                == "Scheduler on: click to turn it off")
        let rec = { (s: Int) in ScheduleButtonModel(state: .recording(item, elapsed: s, marginDb: 9, until: start), zone: utc).accessibilityLabel }
        #expect(rec(724) == "Recording on schedule, 12 minutes 4 seconds: click to stop this recording")
        #expect(rec(3_720) == "Recording on schedule, 1 hour 2 minutes: click to stop this recording")
        #expect(rec(1) == "Recording on schedule, 1 second: click to stop this recording")
        #expect(ScheduleButtonModel(state: .watching(item, caught: 0, until: start), zone: utc).accessibilityLabel
                == "Pirate watch: click to stop watching")
    }
}
