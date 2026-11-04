import Foundation

/// The clock maths: when a schedule's runs happen, in the schedule's own zone.
public enum ScheduleClock {
    /// A broadcast's window opens this long before its start and closes this long after its end; a watch's is exact.
    public static let broadcastLead: TimeInterval = 60
    public static let broadcastLag: TimeInterval = 120

    /// Every run window of `s` that overlaps `[from, to)`, in order. A window belongs to the day its start falls on,
    /// in `s.timeZone`, and may run past midnight. `startDate`/`endDate` bound the start day.
    public static func windows(of s: Schedule, from: Date, to: Date) -> [DateInterval] {
        guard from < to else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: s.timeZone) ?? TimeZone(identifier: "UTC")!
        let lead = s.kind == .broadcast ? broadcastLead : 0
        let lag = s.kind == .broadcast ? broadcastLag : 0
        let length = TimeInterval(max(0, s.durationMinutes) * 60)

        // The earliest start day that can still reach `from`, one day of slack for zone offsets.
        var day = calendar.startOfDay(for: from.addingTimeInterval(-(length + lag + 86_400)))
        var found: [DateInterval] = []
        while day < to.addingTimeInterval(lead + 86_400) {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let date = ScheduleDate(year: parts.year!, month: parts.month!, day: parts.day!)
            if runs(s, on: date, calendar: calendar),
               let begin = calendar.nextDate(after: day.addingTimeInterval(-1),
                                             matching: DateComponents(hour: s.start.hour, minute: s.start.minute),
                                             matchingPolicy: .nextTime) {
                let window = DateInterval(start: begin.addingTimeInterval(-lead),
                                          end: begin.addingTimeInterval(length + lag))
                if window.end > from && window.start < to { found.append(window) }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return found
    }

    /// The first window whose end is after `date` (it may already have begun), searching 400 days ahead in
    /// growing chunks so a frequent schedule answers from the first few days.
    public static func nextWindow(of s: Schedule, after date: Date) -> DateInterval? {
        if let last = lastPossibleEnd(of: s), last < date { return nil }
        var from = date
        for days in [8, 32, 360] {
            let to = from.addingTimeInterval(TimeInterval(days) * 86_400)
            if let first = windows(of: s, from: from, to: to).first { return first }
            from = to
        }
        return nil
    }

    /// A bound past which a `.once` or `endDate`-limited schedule has no windows (slack for zones and DST).
    private static func lastPossibleEnd(of s: Schedule) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: s.timeZone) ?? TimeZone(identifier: "UTC")!
        var lastDay: ScheduleDate?
        if case .once(let only) = s.days { lastDay = only }
        if let end = s.endDate, lastDay == nil || key(end) < key(lastDay!) { lastDay = end }
        guard let d = lastDay,
              let noon = calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: 12))
        else { return nil }
        let reach = TimeInterval(max(0, s.durationMinutes) * 60) + broadcastLag
        return noon.addingTimeInterval(2 * 86_400 + reach)
    }

    private static func runs(_ s: Schedule, on d: ScheduleDate, calendar: Calendar) -> Bool {
        if let a = s.startDate, key(d) < key(a) { return false }
        if let b = s.endDate, key(d) > key(b) { return false }
        switch s.days {
        case .once(let only):
            return d == only
        case .weekly(let set):
            return set.contains(weekday(of: d, calendar: calendar))
        case .monthly(let ordinal, let wd):
            guard weekday(of: d, calendar: calendar) == wd else { return false }
            if ordinal == -1 {
                let first = calendar.date(from: DateComponents(year: d.year, month: d.month, day: 1))!
                let length = calendar.range(of: .day, in: .month, for: first)!.count
                return d.day + 7 > length
            }
            return (d.day - 1) / 7 + 1 == ordinal
        }
    }

    private static func key(_ d: ScheduleDate) -> Int { d.year * 10_000 + d.month * 100 + d.day }

    private static func weekday(of d: ScheduleDate, calendar: Calendar) -> Weekday {
        let noon = calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: 12))!
        let w = calendar.component(.weekday, from: noon)          // Sunday = 1
        return Weekday(rawValue: (w + 5) % 7 + 1)!
    }
}
