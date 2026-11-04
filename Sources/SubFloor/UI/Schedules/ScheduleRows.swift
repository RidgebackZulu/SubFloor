import Foundation
import Scheduling

/// How a schedule's days and times read in the Schedules window: the owner's local days and times, with UTC in
/// brackets (`Fri, Sat 19:00–02:00 (01:00–08:00 UTC)`). The days are the local ones, so they shift when the local
/// time falls on another day than the schedule's own zone (a UTC schedule shows the local equivalent first).
enum ScheduleWhen {
    private static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func name(_ d: Weekday) -> String { weekdayNames[d.rawValue - 1] }

    /// "20 Nov" in `zone`.
    static func dayAndMonth(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.day, .month], from: date)
        return "\(c.day!) \(monthNames[c.month! - 1])"
    }

    /// "Fri 6 Nov 19:00": a run's start in `zone`.
    static func runStart(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let wd = calendar.component(.weekday, from: date)            // Sunday = 1
        return "\(weekdayNames[(wd + 5) % 7]) \(dayAndMonth(date, in: zone)) \(clock(date, in: zone))"
    }

    static func clock(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    /// An instant at which `s` starts (its nominal start, not the window's lead): the next one, or for a `.once` the
    /// date itself, or today's time when there's none left. Daylight saving is read at that instant.
    static func reference(of s: Schedule, now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: s.timeZone) ?? TimeZone(identifier: "UTC")!
        let at = DateComponents(hour: s.start.hour, minute: s.start.minute)
        if case .once(let d) = s.days,
           let date = calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day,
                                                         hour: s.start.hour, minute: s.start.minute)) {
            return date
        }
        if let w = ScheduleClock.nextWindow(of: s, after: now) {
            return w.start.addingTimeInterval(s.kind == .broadcast ? ScheduleClock.broadcastLead : 0)
        }
        return calendar.nextDate(after: calendar.startOfDay(for: now).addingTimeInterval(-1), matching: at,
                                 matchingPolicy: .nextTime) ?? now
    }

    /// The start's UTC minute of the day, as it stands at `reference(of:now:)`.
    static func utcMinutes(of s: Schedule, now: Date) -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.hour, .minute], from: reference(of: s, now: now))
        return c.hour! * 60 + c.minute!
    }

    static func text(of s: Schedule, now: Date, zone: TimeZone) -> String {
        let utcZone = TimeZone(identifier: "UTC")!
        let start = reference(of: s, now: now)
        let end = start.addingTimeInterval(TimeInterval(s.durationMinutes * 60))
        let local = "\(clock(start, in: zone))–\(clock(end, in: zone))"
        let utc = "\(clock(start, in: utcZone))–\(clock(end, in: utcZone))"

        var own = Calendar(identifier: .gregorian)
        own.timeZone = TimeZone(identifier: s.timeZone) ?? utcZone
        var shown = Calendar(identifier: .gregorian)
        shown.timeZone = zone
        var shift = shown.component(.weekday, from: start) - own.component(.weekday, from: start)
        if shift > 3 { shift -= 7 } else if shift < -3 { shift += 7 }

        let days: String
        switch s.days {
        case .weekly(let set):
            let moved = Set(set.map { Weekday(rawValue: ((($0.rawValue - 1 + shift) % 7) + 7) % 7 + 1)! })
            if moved.count == 7 { days = "Daily" }
            else if moved == [.mo, .tu, .we, .th, .fr] { days = "Mon–Fri" }
            else { days = moved.sorted().map(name).joined(separator: ", ") }
        case .monthly(let ordinal, let weekday):
            let ord = ordinal == -1 ? "Last" : ["1st", "2nd", "3rd", "4th", "5th"][max(0, min(4, ordinal - 1))]
            // "1st Saturday" doesn't carry over to another date, so a shifted one is shown in its own zone.
            if shift != 0 {
                let ownStart = own.dateComponents([.hour, .minute], from: start)
                let ownEnd = own.dateComponents([.hour, .minute], from: end)
                return String(format: "%@ %@ %02d:%02d–%02d:%02d (%@)", ord, name(weekday), ownStart.hour!, ownStart.minute!,
                              ownEnd.hour!, ownEnd.minute!, s.timeZone)
            }
            days = "\(ord) \(name(weekday))"
        case .once:
            days = dayAndMonth(start, in: zone)
        }
        return "\(days) \(local) (\(utc) UTC)"
    }
}

/// kHz as people write them: 9435, 5890.5.
func kHzText(_ hz: Double) -> String {
    let khz = hz / 1000
    return khz == khz.rounded() ? String(Int(khz)) : String(format: "%g", (khz * 1000).rounded() / 1000)
}

extension ScheduleMode {
    var label: String { self == .auto ? "Auto" : rawValue.uppercased() }
}

/// One line of My schedules.
struct ScheduleRow: Identifiable, Equatable {
    let schedule: Schedule
    let title: String
    /// "9435, 9455 kHz · AM" or "6925–7075 kHz · Auto"
    let tuning: String
    /// Local days and times, UTC in brackets.
    let when: String
    /// "Fri 6 Nov 19:00", or "—" when off or there's none.
    let nextRun: String
    /// "you" or the agent's client name.
    let addedBy: String
    /// `RunOutcome.text`, or "Not run yet".
    let lastOutcome: String
    /// "Updated from the timetable 3 Nov", "No longer in the timetable", "Irregular in the timetable".
    let note: String?
    /// "Overlaps with A, B"
    let overlapText: String?

    var id: UUID { schedule.id }

    init(schedule s: Schedule, now: Date, zone: TimeZone, overlaps: [String] = []) {
        schedule = s
        title = s.name
        switch s.kind {
        case .broadcast:
            tuning = "\(s.frequenciesHz.map(kHzText).joined(separator: ", ")) kHz · \(s.mode.label)"
        case .watch:
            tuning = "\(kHzText(s.lowHz ?? 0))–\(kHzText(s.highHz ?? 0)) kHz · \(s.mode.label)"
        }
        when = ScheduleWhen.text(of: s, now: now, zone: zone)
        if s.enabled, let w = ScheduleClock.nextWindow(of: s, after: now) {
            let start = w.start.addingTimeInterval(s.kind == .broadcast ? ScheduleClock.broadcastLead : 0)
            nextRun = ScheduleWhen.runStart(start, in: zone)
        } else {
            nextRun = "—"
        }
        addedBy = s.addedBy ?? "you"
        lastOutcome = s.lastRun?.outcome.text ?? "Not run yet"
        switch s.timetableNote {
        case .updated(let date): note = "Updated from the timetable \(ScheduleWhen.dayAndMonth(date, in: zone))"
        case .gone: note = "No longer in the timetable"
        case .irregular: note = "Irregular in the timetable"
        case nil: note = nil
        }
        overlapText = overlaps.isEmpty ? nil : "Overlaps with \(overlaps.joined(separator: ", "))"
    }
}

/// One line of the Timetable tab.
struct TimetableRow: Identifiable {
    let broadcast: TimetableBroadcast
    let zone: TimeZone
    let now: Date
    /// Set by the window's model: a schedule already carries this broadcast.
    var added = false

    var id: String { broadcast.id }
    var station: String { broadcast.station }
    var language: String { broadcast.language }
    var country: String { broadcast.country }
    /// EiBi flagged it irregular, tentative or a test.
    var uncertain: Bool { broadcast.irregular }
    var frequencies: String { broadcast.frequenciesHz.map(kHzText).joined(separator: ", ") + " kHz" }

    init(broadcast: TimetableBroadcast, zone: TimeZone, now: Date = Date()) {
        self.broadcast = broadcast; self.zone = zone; self.now = now
    }

    /// Local days and times, UTC in brackets.
    var when: String {
        ScheduleWhen.text(of: Schedule(kind: .broadcast, name: broadcast.station, frequenciesHz: broadcast.frequenciesHz,
                                       mode: .am, start: broadcast.start, durationMinutes: broadcast.durationMinutes,
                                       timeZone: "UTC", days: broadcast.days, startDate: broadcast.startDate,
                                       endDate: broadcast.endDate, created: now), now: now, zone: zone)
    }
}
