import Foundation

/// A station's transmission seen as one thing: the EiBi rows that differ only in frequency, merged.
public struct TimetableBroadcast: Identifiable, Hashable, Sendable {
    /// station|language|HHMM|days field
    public var id: String
    public var station: String
    public var language: String
    public var country: String
    public var target: String
    public var start: TimeOfDay            // UTC
    public var durationMinutes: Int
    public var days: ScheduleDays
    public var irregular: Bool
    public var startDate: ScheduleDate?
    public var endDate: ScheduleDate?
    public var frequenciesHz: [Double]     // ascending, distinct
}

/// The North America part of one EiBi season: audible here, on air this season, and not religious.
public struct Timetable: Sendable {
    public static let northAmericaTargets: Set<String> = ["NAm", "ENA", "CNA", "WNA", "Am", "Car", "CAm", "USA"]

    public let season: EiBiSeason
    /// North America targeted, active, not religious, merged; by start time.
    public let broadcasts: [TimetableBroadcast]
    /// Rows the parser couldn't use (only set by `init(data:…)`).
    public let droppedRows: Int

    public init(rows: [EiBiRow], season: EiBiSeason, filter: ReligiousFilter = .bundled) {
        self.init(rows: rows, dropped: 0, season: season, filter: filter)
    }

    /// Parses `data` (an EiBi CSV) and builds the timetable from it.
    public init(data: Data, season: EiBiSeason, filter: ReligiousFilter = .bundled) {
        let (rows, dropped) = EiBi.parse(data)
        self.init(rows: rows, dropped: dropped, season: season, filter: filter)
    }

    private init(rows: [EiBiRow], dropped: Int, season: EiBiSeason, filter: ReligiousFilter) {
        self.season = season
        self.droppedRows = dropped
        var merged: [String: TimetableBroadcast] = [:]
        for row in rows where Self.isActive(row, in: season) && Self.targetsNorthAmerica(row) && !filter.isReligious(row.station) {
            guard let (days, irregular) = EiBi.days(row.daysField, season: season) else { continue }
            let start = row.start.hour * 60 + row.start.minute
            var length = row.end.hour * 60 + row.end.minute - start
            if length <= 0 { length += 1440 }
            let id = String(format: "%@|%@|%02d%02d|%@", row.station, row.language, row.start.hour, row.start.minute, row.daysField)
            let hz = (row.kHz * 1000).rounded()
            let key = "\(id)|\(length)"
            if var existing = merged[key] {
                if !existing.frequenciesHz.contains(hz) { existing.frequenciesHz.append(hz) }
                merged[key] = existing
            } else {
                merged[key] = TimetableBroadcast(
                    id: id, station: row.station, language: row.language, country: row.country, target: row.target,
                    start: row.start, durationMinutes: length, days: days, irregular: irregular,
                    startDate: EiBi.date(row.startField, in: season), endDate: EiBi.date(row.stopField, in: season),
                    frequenciesHz: [hz])
            }
        }
        broadcasts = merged.values.map { b in var b = b; b.frequenciesHz.sort(); return b }
            .sorted { ($0.start.hour * 60 + $0.start.minute, $0.station, $0.id, $0.durationMinutes)
                    < ($1.start.hour * 60 + $1.start.minute, $1.station, $1.id, $1.durationMinutes) }
    }

    /// Not inactive (8), not a utility station (90+), and on air in this season's half (4 is winter only, 5 summer only).
    private static func isActive(_ row: EiBiRow, in season: EiBiSeason) -> Bool {
        guard let p = row.persistence else { return true }
        if p == 8 || p >= 90 { return false }
        return !(p == 4 && season.half == .a) && !(p == 5 && season.half == .b)
    }

    private static func targetsNorthAmerica(_ row: EiBiRow) -> Bool {
        row.target.split(whereSeparator: { $0 == "," || $0 == "/" })
            .contains { northAmericaTargets.contains($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// The bundled `sked-b26.csv`. A missing file is a programmer error (precondition).
    public static func bundledData() -> Data {
        guard let url = Bundle.module.url(forResource: "sked-b26", withExtension: "csv", subdirectory: "Resources"),
              let data = try? Data(contentsOf: url) else { preconditionFailure("sked-b26.csv is missing or unreadable") }
        return data
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Station, language or country contain every word of `query` (case- and accent-insensitive). `language` and
    /// `country` narrow to exactly that code.
    public func search(_ query: String, language: String? = nil, country: String? = nil) -> [TimetableBroadcast] {
        let words = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        return broadcasts.filter { b in
            if let language, Self.fold(b.language) != Self.fold(language) { return false }
            if let country, Self.fold(b.country) != Self.fold(country) { return false }
            let haystack = Self.fold([b.station, b.language, b.country].joined(separator: " "))
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// Broadcasts with a window starting in the next 24 hours from `now`.
    public func onTonight(now: Date) -> [TimetableBroadcast] {
        let end = now.addingTimeInterval(86_400)
        return broadcasts.filter { b in
            ScheduleClock.windows(of: schedule(from: b, now: now, addedBy: nil), from: now, to: end + ScheduleClock.broadcastLead)
                .contains { $0.start >= now && $0.start < end }
        }
    }

    /// A new broadcast schedule from `b`: all its frequencies, its days, AM, UTC, `timetableKey`, `.timetable` source,
    /// enabled, margin 8, a note of `.irregular` when `b.irregular`. 9 or more frequencies keep the first 8.
    public func schedule(from b: TimetableBroadcast, now: Date, addedBy: String?) -> Schedule {
        Schedule(kind: .broadcast, name: b.station, frequenciesHz: Array(b.frequenciesHz.prefix(8)), mode: .am,
                 start: b.start, durationMinutes: b.durationMinutes, timeZone: "UTC", days: b.days,
                 startDate: b.startDate, endDate: b.endDate,
                 timetableKey: TimetableKey(station: b.station, language: b.language, season: season.name),
                 timetableNote: b.irregular ? .irregular : nil, enabled: true, squelchMarginDb: 8,
                 addedBy: addedBy, source: .timetable, created: now)
    }

    /// For each schedule with a `timetableKey`: the same station and language, the closest start time (preferring a
    /// shared weekday, the earlier start on a tie). When found, it takes that broadcast's times, days, dates and
    /// frequencies, this season's key, and note `.updated(now)`. When not found, it's switched off with note `.gone`.
    /// Other schedules are untouched.
    public func relink(_ schedules: [Schedule], now: Date) -> [Schedule] {
        schedules.map { s in
            guard let key = s.timetableKey else { return s }
            var out = s
            let wanted = Self.weekdays(of: s.days)
            let minutes = s.start.hour * 60 + s.start.minute
            let best = broadcasts.filter { $0.station == key.station && $0.language == key.language }
                .min { a, b in rank(a, minutes, wanted) < rank(b, minutes, wanted) }
            guard let best else {
                out.enabled = false; out.timetableNote = .gone
                return out
            }
            out.start = best.start; out.durationMinutes = best.durationMinutes; out.days = best.days
            out.startDate = best.startDate; out.endDate = best.endDate
            out.frequenciesHz = Array(best.frequenciesHz.prefix(8))
            out.timetableKey = TimetableKey(station: best.station, language: best.language, season: season.name)
            out.timetableNote = .updated(now)
            return out
        }
    }

    private func rank(_ b: TimetableBroadcast, _ minutes: Int, _ wanted: Set<Weekday>) -> (Int, Int, Int) {
        let start = b.start.hour * 60 + b.start.minute
        let gap = abs(start - minutes)
        return (wanted.isDisjoint(with: Self.weekdays(of: b.days)) ? 1 : 0, min(gap, 1440 - gap), start)
    }

    private static func weekdays(of days: ScheduleDays) -> Set<Weekday> {
        switch days {
        case .weekly(let set): return set
        case .monthly(_, let weekday): return [weekday]
        case .once(let d):
            guard let date = EiBi.utc.date(from: DateComponents(year: d.year, month: d.month, day: d.day)) else { return [] }
            let sundayFirst = EiBi.utc.component(.weekday, from: date)          // Sunday = 1
            return [Weekday(rawValue: (sundayFirst + 5) % 7 + 1)!]
        }
    }
}
