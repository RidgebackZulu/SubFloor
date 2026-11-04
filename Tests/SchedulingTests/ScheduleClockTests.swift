import Foundation
import Testing
@testable import Scheduling

private let zone = "America/Chicago"

private func utc(_ s: String) -> Date {
    ISO8601DateFormatter().date(from: s)!
}

private func schedule(kind: ScheduleKind = .broadcast, start: TimeOfDay, minutes: Int, zone: String = zone,
                      days: ScheduleDays, startDate: ScheduleDate? = nil, endDate: ScheduleDate? = nil) -> Schedule {
    Schedule(id: UUID(), kind: kind, name: "Test", frequenciesHz: kind == .broadcast ? [9_400_000] : [],
             lowHz: nil, highHz: nil, mode: kind == .broadcast ? .am : .auto,
             start: start, durationMinutes: minutes, timeZone: zone, days: days,
             startDate: startDate, endDate: endDate, created: utc("2026-11-01T00:00:00Z"))
}

@Suite struct ScheduleClockTests {
    @Test func weekendWatchFollowsDallasClockAcrossDST() {
        let watch = schedule(kind: .watch, start: .init(hour: 19, minute: 0), minutes: 420, days: .weekly([.fr, .sa]))
        // Friday 30 Oct 2026 is CDT (UTC-5); Friday 6 Nov 2026 is CST (UTC-6).
        #expect(ScheduleClock.nextWindow(of: watch, after: utc("2026-10-30T12:00:00Z")) ==
                DateInterval(start: utc("2026-10-31T00:00:00Z"), end: utc("2026-10-31T07:00:00Z")))
        #expect(ScheduleClock.nextWindow(of: watch, after: utc("2026-11-03T12:00:00Z")) ==
                DateInterval(start: utc("2026-11-07T01:00:00Z"), end: utc("2026-11-07T08:00:00Z")))
    }

    @Test func utcBroadcastGetsLeadAndLag() {
        let b = schedule(kind: .broadcast, start: .init(hour: 2, minute: 0), minutes: 60, zone: "UTC", days: .weekly([.sa]))
        #expect(ScheduleClock.nextWindow(of: b, after: utc("2026-11-03T00:00:00Z")) ==
                DateInterval(start: utc("2026-11-07T01:59:00Z"), end: utc("2026-11-07T03:02:00Z")))
    }

    @Test func windowCrossingMidnightBelongsToItsStartDay() {
        let w = schedule(kind: .watch, start: .init(hour: 23, minute: 30), minutes: 90, zone: "UTC", days: .weekly([.sa]))
        // Sunday 8 Nov holds the tail of Saturday's window but starts none.
        let found = ScheduleClock.windows(of: w, from: utc("2026-11-08T00:00:00Z"), to: utc("2026-11-08T23:59:00Z"))
        // Windows overlapping the range include Saturday's tail; none starts on Sunday itself.
        #expect(found == [DateInterval(start: utc("2026-11-07T23:30:00Z"), end: utc("2026-11-08T01:00:00Z"))])
        #expect(ScheduleClock.windows(of: w, from: utc("2026-11-08T01:00:00Z"), to: utc("2026-11-14T00:00:00Z")).isEmpty)
        // After the Saturday window has ended, the next one is a week on.
        #expect(ScheduleClock.nextWindow(of: w, after: utc("2026-11-08T01:00:00Z"))?.start == utc("2026-11-14T23:30:00Z"))
    }

    @Test func onceRunsOnItsDateOnly() {
        let o = schedule(kind: .watch, start: .init(hour: 21, minute: 0), minutes: 30,
                         days: .once(ScheduleDate(year: 2026, month: 11, day: 20)))
        // 21:00 CST = 03:00 UTC next day.
        let w = ScheduleClock.nextWindow(of: o, after: utc("2026-11-03T00:00:00Z"))
        #expect(w == DateInterval(start: utc("2026-11-21T03:00:00Z"), end: utc("2026-11-21T03:30:00Z")))
        #expect(ScheduleClock.nextWindow(of: o, after: w!.end) == nil)
    }

    @Test func monthlyNthAndLastWeekday() {
        let first = schedule(kind: .watch, start: .init(hour: 12, minute: 0), minutes: 60, zone: "UTC", days: .monthly(ordinal: 1, weekday: .sa))
        #expect(ScheduleClock.nextWindow(of: first, after: utc("2026-11-01T00:00:00Z"))?.start == utc("2026-11-07T12:00:00Z"))
        let last = schedule(kind: .watch, start: .init(hour: 12, minute: 0), minutes: 60, zone: "UTC", days: .monthly(ordinal: -1, weekday: .su))
        #expect(ScheduleClock.nextWindow(of: last, after: utc("2026-11-01T00:00:00Z"))?.start == utc("2026-11-29T12:00:00Z"))
    }

    @Test func startAndEndDatesBoundTheStartDay() {
        let d = schedule(kind: .watch, start: .init(hour: 10, minute: 0), minutes: 30, zone: "UTC",
                         days: .weekly(Set(Weekday.allCases)),
                         startDate: ScheduleDate(year: 2026, month: 11, day: 10),
                         endDate: ScheduleDate(year: 2026, month: 11, day: 12))
        let found = ScheduleClock.windows(of: d, from: utc("2026-11-01T00:00:00Z"), to: utc("2026-12-01T00:00:00Z"))
        #expect(found.map(\.start) == [utc("2026-11-10T10:00:00Z"), utc("2026-11-11T10:00:00Z"), utc("2026-11-12T10:00:00Z")])
    }

    @Test func windowAlreadyBegunIsTheNextWindow() {
        let w = schedule(kind: .watch, start: .init(hour: 19, minute: 0), minutes: 420, days: .weekly([.fr]))
        // Friday 6 Nov 20:30 CST = Saturday 02:30 UTC.
        #expect(ScheduleClock.nextWindow(of: w, after: utc("2026-11-07T02:30:00Z")) ==
                DateInterval(start: utc("2026-11-07T01:00:00Z"), end: utc("2026-11-07T08:00:00Z")))
    }

    @Test func windowsInRangeAreOrdered() {
        let w = schedule(kind: .watch, start: .init(hour: 19, minute: 0), minutes: 420, days: .weekly([.fr, .sa]))
        let found = ScheduleClock.windows(of: w, from: utc("2026-11-02T00:00:00Z"), to: utc("2026-11-16T00:00:00Z"))
        #expect(found.count == 4)
        #expect(found.map(\.start) == found.map(\.start).sorted())
    }

    @Test func springForwardGapTakesNextValidTime() {
        // 2:30 local does not exist on 8 Mar 2026 in Chicago.
        let s = schedule(kind: .watch, start: .init(hour: 2, minute: 30), minutes: 60,
                         days: .once(ScheduleDate(year: 2026, month: 3, day: 8)))
        let w = ScheduleClock.nextWindow(of: s, after: utc("2026-03-01T00:00:00Z"))
        #expect(w != nil)
        #expect(w!.start >= utc("2026-03-08T08:00:00Z") && w!.start <= utc("2026-03-08T09:00:00Z"))
    }

    @Test func scheduleRoundTripsThroughJSON() throws {
        let all: [ScheduleDays] = [.weekly([.mo, .su]), .monthly(ordinal: -1, weekday: .fr),
                                   .once(ScheduleDate(year: 2026, month: 12, day: 25))]
        for days in all {
            var s = schedule(start: .init(hour: 1, minute: 2), minutes: 3, days: days)
            s.timetableKey = TimetableKey(station: "BBC", language: "E", season: "b26")
            s.timetableNote = .updated(utc("2026-11-02T00:00:00Z"))
            s.lastRun = LastRun(outcome: .recorded(seconds: 12, files: 2), at: utc("2026-11-02T01:00:00Z"))
            let data = try JSONEncoder().encode(s)
            #expect(try JSONDecoder().decode(Schedule.self, from: data) == s)
            #expect(s.tag == ScheduleTag(id: s.id, name: "Test"))
        }
    }

    @Test func deadSchedulesHaveNoNextWindow() {
        let once = schedule(start: .init(hour: 21, minute: 0), minutes: 30, days: .once(ScheduleDate(year: 2026, month: 10, day: 1)))
        #expect(ScheduleClock.nextWindow(of: once, after: utc("2026-11-03T00:00:00Z")) == nil)
        let ended = schedule(start: .init(hour: 21, minute: 0), minutes: 30, days: .weekly(Set(Weekday.allCases)),
                             endDate: ScheduleDate(year: 2026, month: 10, day: 1))
        #expect(ScheduleClock.nextWindow(of: ended, after: utc("2026-11-03T00:00:00Z")) == nil)
        let live = schedule(start: .init(hour: 21, minute: 0), minutes: 30, days: .weekly(Set(Weekday.allCases)),
                            endDate: ScheduleDate(year: 2026, month: 11, day: 5))
        #expect(ScheduleClock.nextWindow(of: live, after: utc("2026-11-03T00:00:00Z")) != nil)
    }
}
