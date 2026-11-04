import Foundation
import Testing
@testable import Scheduling

private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

private func make(_ name: String, kind: ScheduleKind = .broadcast, hour: Int, minute: Int = 0, minutes: Int = 60,
                  created: String = "2026-11-01T00:00:00Z", enabled: Bool = true,
                  days: ScheduleDays = .weekly(Set(Weekday.allCases))) -> Schedule {
    Schedule(kind: kind, name: name, frequenciesHz: kind == .broadcast ? [9_435_000] : [],
             lowHz: kind == .watch ? 6_900_000 : nil, highHz: kind == .watch ? 7_000_000 : nil,
             mode: kind == .broadcast ? .am : .auto, start: .init(hour: hour, minute: minute),
             durationMinutes: minutes, timeZone: "UTC", days: days, enabled: enabled, created: utc(created))
}

private func window(_ s: Schedule, at date: Date) -> DateInterval {
    ScheduleClock.nextWindow(of: s, after: date)!
}

private func run(_ s: Schedule, at date: Date) -> ActiveRun {
    ActiveRun(scheduleID: s.id, window: window(s, at: date), kind: s.kind, startedEarly: false)
}

private func tick(_ schedules: [Schedule], on: Bool = true, now: String, lastTick: String?, lastAlive: String? = nil,
                  running: ActiveRun? = nil, settled: Set<RunKey> = []) -> [PlannerAction] {
    SchedulePlanner.tick(schedules: schedules, on: on, now: utc(now), lastTick: lastTick.map(utc),
                         lastAlive: lastAlive.map(utc), running: running, settled: settled)
}

@Suite struct SchedulePlannerTests {
    @Test func startsWhenTheWindowOpens() {
        let w = make("Pirates", kind: .watch, hour: 21)
        let actions = tick([w], now: "2026-11-03T21:00:02Z", lastTick: "2026-11-03T21:00:01Z")
        #expect(actions == [.start(w.id, window: window(w, at: utc("2026-11-03T21:00:00Z")), late: false)])
    }

    @Test func lateStartIsNotMissed() {
        let w = make("Pirates", kind: .watch, hour: 21)
        let actions = tick([w], now: "2026-11-03T21:30:00Z", lastTick: nil, lastAlive: "2026-11-03T20:00:00Z")
        #expect(actions == [.start(w.id, window: window(w, at: utc("2026-11-03T21:30:00Z")), late: true)])
    }

    @Test func sleptThroughAWholeWindow() {
        let b = make("Korea", hour: 21)
        let actions = tick([b], now: "2026-11-04T03:00:00Z", lastTick: "2026-11-03T20:00:00Z")
        #expect(actions.contains(.log(b.id, .missedAsleep, at: utc("2026-11-03T20:59:00Z"))))
        #expect(!actions.contains { if case .start = $0 { true } else { false } })
    }

    @Test func notRunningThroughAWindow() {
        let b = make("Korea", hour: 21, days: .once(.init(year: 2026, month: 11, day: 3)))
        #expect(tick([b], now: "2026-11-04T03:00:00Z", lastTick: nil, lastAlive: "2026-11-03T20:00:00Z")
                == [.log(b.id, .missedNotRunning, at: utc("2026-11-03T20:59:00Z"))])
        // Nothing known about when SubFloor last ran: nothing to report.
        #expect(tick([b], now: "2026-11-04T03:00:00Z", lastTick: nil, lastAlive: nil).isEmpty)
    }

    @Test func aShortGapIsNotASleep() {
        let b = make("Korea", hour: 21, days: .once(.init(year: 2026, month: 11, day: 3)))
        #expect(tick([b], now: "2026-11-03T22:03:00Z", lastTick: "2026-11-03T22:02:58Z").isEmpty)
    }

    @Test func settledWindowIsNotMissed() {
        let b = make("Korea", hour: 21, days: .once(.init(year: 2026, month: 11, day: 3)))
        let key = RunKey(scheduleID: b.id, window: window(b, at: utc("2026-11-03T20:00:00Z")))
        #expect(tick([b], now: "2026-11-04T03:00:00Z", lastTick: "2026-11-03T20:00:00Z", settled: [key]).isEmpty)
    }

    @Test func switchOffStartsAndLogsNothing() {
        let b = make("Korea", hour: 21, days: .once(.init(year: 2026, month: 11, day: 3)))
        let w = make("Pirates", kind: .watch, hour: 3, days: .once(.init(year: 2026, month: 11, day: 4)))
        #expect(tick([b, w], on: false, now: "2026-11-04T03:30:00Z", lastTick: "2026-11-03T20:00:00Z").isEmpty)
        #expect(tick([w], on: false, now: "2026-11-04T03:30:00Z", lastTick: nil, lastAlive: "2026-11-03T20:00:00Z").isEmpty)
    }

    @Test func disabledSchedulesAreIgnored() {
        let w = make("Pirates", kind: .watch, hour: 21, enabled: false)
        #expect(tick([w], now: "2026-11-03T21:10:00Z", lastTick: "2026-11-03T21:09:59Z").isEmpty)
        #expect(tick([w], now: "2026-11-04T03:00:00Z", lastTick: "2026-11-03T20:00:00Z").isEmpty)
    }

    @Test func broadcastPreemptsAWatchAndTheWatchResumes() {
        let watch = make("Pirates", kind: .watch, hour: 20, minutes: 240)
        let b = make("Korea", hour: 21, minutes: 30)
        let watching = run(watch, at: utc("2026-11-03T20:30:00Z"))
        let bWindow = window(b, at: utc("2026-11-03T21:00:00Z"))      // 20:59 – 21:32

        let opening = tick([watch, b], now: "2026-11-03T20:59:00Z", lastTick: "2026-11-03T20:58:59Z", running: watching)
        #expect(opening == [.preempt(running: watch.id, by: b.id, window: bWindow)])

        // The broadcast now holds the radio; the preempted watch is neither logged nor started.
        let during = tick([watch, b], now: "2026-11-03T21:10:00Z", lastTick: "2026-11-03T21:09:59Z",
                          running: ActiveRun(scheduleID: b.id, window: bWindow, kind: .broadcast, startedEarly: true))
        #expect(during.isEmpty)

        let after = tick([watch, b], now: "2026-11-03T21:32:00Z", lastTick: "2026-11-03T21:31:59Z",
                         running: ActiveRun(scheduleID: b.id, window: bWindow, kind: .broadcast, startedEarly: true))
        #expect(after == [.end(b.id), .start(watch.id, window: watching.window, late: true)])
    }

    @Test func runningBroadcastKeepsTheRadio() {
        let a = make("Voice of Korea", hour: 21)
        let b = make("Radio Habana Cuba", hour: 21, minute: 30, created: "2026-11-02T00:00:00Z")
        let running = run(a, at: utc("2026-11-03T21:10:00Z"))
        let first = tick([a, b], now: "2026-11-03T21:29:30Z", lastTick: "2026-11-03T21:29:29Z", running: running)
        #expect(first == [.log(b.id, .overlapped(with: "Voice of Korea"), at: utc("2026-11-03T21:29:30Z"))])

        let key = RunKey(scheduleID: b.id, window: window(b, at: utc("2026-11-03T21:29:30Z")))
        #expect(tick([a, b], now: "2026-11-03T21:29:31Z", lastTick: "2026-11-03T21:29:30Z", running: running).count == 1)
        #expect(tick([a, b], now: "2026-11-03T21:29:31Z", lastTick: "2026-11-03T21:29:30Z", running: running,
                     settled: [key]).isEmpty)
    }

    @Test func overlappedBroadcastDoesNotStartWhenTheRunningOneEnds() {
        let a = make("Voice of Korea", hour: 21)                 // 20:59 – 22:02
        let b = make("Radio Habana Cuba", hour: 21, minute: 30, created: "2026-11-02T00:00:00Z")
        let running = run(a, at: utc("2026-11-03T21:10:00Z"))
        let key = RunKey(scheduleID: b.id, window: window(b, at: utc("2026-11-03T21:29:30Z")))
        let actions = tick([a, b], now: "2026-11-03T22:02:00Z", lastTick: "2026-11-03T22:01:59Z", running: running,
                           settled: [key])
        #expect(actions == [.end(a.id)])
    }

    @Test func sameMomentBroadcastBeatsWatch() {
        let watch = make("Pirates", kind: .watch, hour: 21, minutes: 180, created: "2026-10-01T00:00:00Z")
        let b = make("Korea", hour: 21, minute: 1, created: "2026-11-02T00:00:00Z")      // window opens 21:00
        let actions = tick([watch, b], now: "2026-11-03T21:00:03Z", lastTick: "2026-11-03T21:00:02Z")
        let bWindow = window(b, at: utc("2026-11-03T21:00:03Z"))
        #expect(actions == [.start(b.id, window: bWindow, late: false)])      // the watch isn't logged; it waits

        // The broadcast ends inside the watch's window: the watch starts late.
        let running = ActiveRun(scheduleID: b.id, window: bWindow, kind: .broadcast, startedEarly: false)
        let after = tick([watch, b], now: "2026-11-03T22:03:00Z", lastTick: "2026-11-03T22:02:59Z", running: running)
        #expect(after == [.end(b.id), .start(watch.id, window: window(watch, at: utc("2026-11-03T22:03:00Z")), late: true)])
    }

    @Test func sameMomentEarlierCreatedWins() {
        let older = make("Older", hour: 21, created: "2026-10-01T00:00:00Z")
        let newer = make("Newer", hour: 21, created: "2026-11-01T00:00:00Z")
        let actions = tick([newer, older], now: "2026-11-03T20:59:03Z", lastTick: "2026-11-03T20:59:02Z")
        #expect(actions == [.start(older.id, window: window(older, at: utc("2026-11-03T21:00:00Z")), late: false),
                            .log(newer.id, .overlapped(with: "Older"), at: utc("2026-11-03T20:59:03Z"))])

        let w1 = make("First watch", kind: .watch, hour: 21, created: "2026-10-01T00:00:00Z")
        let w2 = make("Second watch", kind: .watch, hour: 21, created: "2026-11-01T00:00:00Z")
        let watches = tick([w2, w1], now: "2026-11-03T21:00:03Z", lastTick: "2026-11-03T21:00:02Z")
        #expect(watches == [.start(w1.id, window: window(w1, at: utc("2026-11-03T21:00:03Z")), late: false),
                            .log(w2.id, .overlapped(with: "First watch"), at: utc("2026-11-03T21:00:03Z"))])
    }

    @Test func settledWindowDoesNotStart() {
        let w = make("Pirates", kind: .watch, hour: 21)
        let key = RunKey(scheduleID: w.id, window: window(w, at: utc("2026-11-03T21:10:00Z")))
        #expect(tick([w], now: "2026-11-03T21:10:00Z", lastTick: "2026-11-03T21:09:59Z", settled: [key]).isEmpty)
    }

    @Test func endsWhenTheWindowCloses() {
        let w = make("Pirates", kind: .watch, hour: 21)
        let running = run(w, at: utc("2026-11-03T21:10:00Z"))
        #expect(tick([w], now: "2026-11-03T21:59:59Z", lastTick: "2026-11-03T21:59:58Z", running: running).isEmpty)
        #expect(tick([w], now: "2026-11-03T22:00:00Z", lastTick: "2026-11-03T21:59:59Z", running: running) == [.end(w.id)])
    }

    @Test func aRunThatWasRunningAcrossASleepIsNotMissed() {
        let w = make("Pirates", kind: .watch, hour: 21, days: .once(.init(year: 2026, month: 11, day: 3)))
        let running = run(w, at: utc("2026-11-03T21:10:00Z"))
        let actions = tick([w], now: "2026-11-03T23:00:00Z", lastTick: "2026-11-03T21:30:00Z", running: running)
        #expect(actions == [.end(w.id)])
    }

    @Test func keepAwakeWithin24Hours() {
        let b = make("Korea", hour: 21, days: .once(.init(year: 2026, month: 11, day: 4)))   // window opens 20:59 on the 4th
        #expect(SchedulePlanner.needsKeepAwake([b], on: true, now: utc("2026-11-03T21:59:00Z")))      // 23 h before
        #expect(!SchedulePlanner.needsKeepAwake([b], on: true, now: utc("2026-11-03T19:59:00Z")))     // 25 h before
        #expect(!SchedulePlanner.needsKeepAwake([b], on: false, now: utc("2026-11-03T21:59:00Z")))
        #expect(SchedulePlanner.needsKeepAwake([b], on: true, now: utc("2026-11-04T21:30:00Z")))      // running now
        var off = b; off.enabled = false
        #expect(!SchedulePlanner.needsKeepAwake([off], on: true, now: utc("2026-11-03T21:59:00Z")))
    }

    @Test func nextListsThreeInOrderIncludingOneRunning() {
        let early = make("Early", hour: 5)
        let late = make("Late", hour: 23)
        let mid = make("Mid", hour: 12)
        let running = make("Running", kind: .watch, hour: 8, minutes: 240)
        let off = make("Off", hour: 9, enabled: false)
        let list = SchedulePlanner.next([late, early, off, mid, running], after: utc("2026-11-03T09:00:00Z"))
        #expect(list.map(\.0.name) == ["Running", "Mid", "Late"])
        #expect(list[0].1.start == utc("2026-11-03T08:00:00Z"))
    }

    @Test func overlapsAreNamed() {
        let a = make("Korea", hour: 21)
        let b = make("Cuba", hour: 21, minute: 30)
        let c = make("Morning", hour: 6)
        var d = make("Disabled", hour: 21); d.enabled = false
        let names = SchedulePlanner.overlaps(of: a, in: [a, b, c, d], now: utc("2026-11-03T00:00:00Z"))
        #expect(names == ["Cuba"])
        #expect(SchedulePlanner.overlaps(of: c, in: [a, b, c, d], now: utc("2026-11-03T00:00:00Z")).isEmpty)
    }

    @Test func backToBackBroadcastsBothRecord() {
        let korea = make("Korea", hour: 21, minutes: 30, created: "2026-10-01T00:00:00Z")     // 20:59 – 21:32
        let cuba = make("Cuba", hour: 21, minute: 30, minutes: 30, created: "2026-11-01T00:00:00Z")  // 21:29 – 22:02
        let running = run(korea, at: utc("2026-11-03T21:10:00Z"))
        // Cuba's window is open but Korea isn't over yet: nothing is logged, Cuba waits.
        #expect(tick([korea, cuba], now: "2026-11-03T21:29:30Z", lastTick: "2026-11-03T21:29:29Z", running: running).isEmpty)
        let handover = tick([korea, cuba], now: "2026-11-03T21:30:00Z", lastTick: "2026-11-03T21:29:59Z", running: running)
        #expect(handover == [.end(korea.id), .start(cuba.id, window: window(cuba, at: utc("2026-11-03T21:30:00Z")), late: true)])
        // On launch in the overlap, only Cuba is left to start.
        let launch = tick([korea, cuba], now: "2026-11-03T21:31:00Z", lastTick: nil)
        #expect(launch == [.start(cuba.id, window: window(cuba, at: utc("2026-11-03T21:31:00Z")), late: true)])
    }

    @Test func backToBackSameMomentBothWaitTheirTurn() {
        let korea = make("Korea", hour: 21, minutes: 30, created: "2026-10-01T00:00:00Z")
        let cuba = make("Cuba", hour: 21, minute: 30, minutes: 30, created: "2026-09-01T00:00:00Z")
        let actions = tick([korea, cuba], now: "2026-11-03T21:29:30Z", lastTick: "2026-11-03T21:29:29Z")
        #expect(actions.count == 1)        // one starts, the other is not logged overlapped
    }

    @Test func broadcastPastItsScheduledEndIsNotStartedLate() {
        let b = make("Korea", hour: 21, minutes: 30)               // window 20:59 – 21:32, scheduled end 21:30
        #expect(tick([b], now: "2026-11-03T21:31:00Z", lastTick: nil).isEmpty)
        #expect(tick([b], now: "2026-11-03T21:29:00Z", lastTick: nil).count == 1)
    }

    @Test func aPartlyRunWindowIsNotMissed() {
        let w = make("Pirates", kind: .watch, hour: 21, days: .once(.init(year: 2026, month: 11, day: 3)))   // 21:00 – 22:00
        #expect(tick([w], now: "2026-11-03T23:30:00Z", lastTick: "2026-11-03T21:30:00Z").isEmpty)
        #expect(tick([w], now: "2026-11-03T23:30:00Z", lastTick: nil, lastAlive: "2026-11-03T21:30:00Z").isEmpty)
    }

    @Test func noOverlapNameForAnUnknownRunningSchedule() {
        let b = make("Korea", hour: 21)
        let ghost = ActiveRun(scheduleID: UUID(), window: DateInterval(start: utc("2026-11-03T20:00:00Z"),
                                                                       end: utc("2026-11-03T23:00:00Z")),
                              kind: .broadcast, startedEarly: false)
        #expect(tick([b], now: "2026-11-03T21:00:00Z", lastTick: "2026-11-03T20:59:59Z", running: ghost).isEmpty)
    }

    @Test func adjacentBroadcastsDoNotOverlap() {
        let korea = make("Korea", hour: 21)
        let cuba = make("Cuba", hour: 22)
        #expect(SchedulePlanner.overlaps(of: korea, in: [korea, cuba], now: utc("2026-11-03T00:00:00Z")).isEmpty)
        // A watch next to a broadcast still counts by window.
        let watch = make("Pirates", kind: .watch, hour: 22)
        #expect(SchedulePlanner.overlaps(of: korea, in: [korea, watch], now: utc("2026-11-03T00:00:00Z")) == ["Pirates"])
    }

    @Test func nextForManySchedulesMatchesABruteForceScan() {
        var all: [Schedule] = []
        for i in 0..<200 {
            let days: ScheduleDays = i % 3 == 0 ? .monthly(ordinal: i % 4 + 1, weekday: Weekday(rawValue: i % 7 + 1)!)
                                                : .weekly([Weekday(rawValue: i % 7 + 1)!])
            all.append(make("S\(i)", kind: i % 2 == 0 ? .watch : .broadcast, hour: i % 24, minute: i % 60, minutes: 30,
                            created: "2026-11-01T00:00:00Z", days: days))
        }
        let now = utc("2026-11-03T09:00:00Z")
        let started = Date()
        let list = SchedulePlanner.next(all, after: now)
        print("next() over 200 schedules took \(Date().timeIntervalSince(started)) s")
        let horizon = now.addingTimeInterval(400 * 86_400)
        var scanned: [(name: String, window: DateInterval)] = []
        for s in all {
            if let first = ScheduleClock.windows(of: s, from: now, to: horizon).first { scanned.append((s.name, first)) }
        }
        scanned.sort { $0.window.start != $1.window.start ? $0.window.start < $1.window.start : $0.name < $1.name }
        let expected: [DateInterval] = scanned.prefix(3).map { $0.window }
        let actual: [DateInterval] = list.map { $0.1 }
        #expect(actual == expected)
        #expect(list.count == 3)
    }
}
