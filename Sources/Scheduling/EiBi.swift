import Foundation

/// One EiBi timetable file: `a` runs from the last Sunday of March, `b` from the last Sunday of October (01:00 UTC).
public struct EiBiSeason: Hashable, Sendable, Codable {
    public enum Half: String, Codable, Sendable { case a, b }
    public var year: Int
    public var half: Half      // b26 = winter 2026/27
    public init(year: Int, half: Half) { self.year = year; self.half = half }

    /// "b26"
    public var name: String { "\(half.rawValue)\(String(format: "%02d", year % 100))" }
    /// http://eibispace.de/dx/sked-b26.csv (plain HTTP: the site's HTTPS certificate has expired).
    public var url: URL { URL(string: "http://eibispace.de/dx/sked-\(name).csv")! }

    public static func current(at date: Date) -> EiBiSeason {
        let year = EiBi.utc.component(.year, from: date)
        if date >= EiBiSeason(year: year, half: .b).startsAt { return EiBiSeason(year: year, half: .b) }
        if date >= EiBiSeason(year: year, half: .a).startsAt { return EiBiSeason(year: year, half: .a) }
        return EiBiSeason(year: year - 1, half: .b)
    }

    public var next: EiBiSeason { half == .a ? EiBiSeason(year: year, half: .b) : EiBiSeason(year: year + 1, half: .a) }
    public var previous: EiBiSeason { half == .b ? EiBiSeason(year: year, half: .a) : EiBiSeason(year: year - 1, half: .b) }

    /// The changeover: 01:00 UTC on the last Sunday of March (a) or October (b).
    public var startsAt: Date {
        let month = half == .a ? 3 : 10
        let lastDay = EiBi.utc.range(of: .day, in: .month, for: EiBi.utc.date(from: DateComponents(year: year, month: month, day: 1))!)!.count
        let last = EiBi.utc.date(from: DateComponents(year: year, month: month, day: lastDay))!
        let back = EiBi.utc.component(.weekday, from: last) - 1       // Sunday = 1, so 0 days back on a Sunday
        return EiBi.utc.date(byAdding: .day, value: -back, to: last)!.addingTimeInterval(3600)
    }

}

/// One line of the EiBi CSV. `end` may be 24:00 (a broadcast that runs to midnight).
public struct EiBiRow: Equatable, Sendable {
    public var kHz: Double
    public var start: TimeOfDay
    public var end: TimeOfDay
    public var daysField: String
    public var country: String
    public var station: String
    public var language: String
    public var target: String
    public var site: String
    public var persistence: Int?
    public var startField: String
    public var stopField: String

    public init(kHz: Double, start: TimeOfDay, end: TimeOfDay, daysField: String, country: String, station: String,
                language: String, target: String, site: String, persistence: Int?, startField: String, stopField: String) {
        self.kHz = kHz; self.start = start; self.end = end; self.daysField = daysField; self.country = country
        self.station = station; self.language = language; self.target = target; self.site = site
        self.persistence = persistence; self.startField = startField; self.stopField = stopField
    }
}

/// The EiBi CSV, which is untrusted text: it is only ever read as fields, never run.
/// Fields: kHz; Time(UTC); Days; ITU; Station; Lng; Target; Remarks (site); P (persistence); Start; Stop.
public enum EiBi {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Latin-1, `;`-separated, header line skipped. Returns the rows that parse and how many didn't (blank lines don't count).
    public static func parse(_ data: Data) -> (rows: [EiBiRow], dropped: Int) {
        let text = String(data: data, encoding: .isoLatin1) ?? ""
        var rows: [EiBiRow] = []
        var dropped = 0
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let row = row(String(line)) { rows.append(row) } else { dropped += 1 }
        }
        return (rows, dropped)
    }

    private static func row(_ line: String) -> EiBiRow? {
        let f = line.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count >= 7, let kHz = Double(f[0]), kHz.isFinite, (10...30_000).contains(kHz),
              let (start, end) = times(f[1]), !f[4].isEmpty, days(f[2], season: probeSeason) != nil else { return nil }
        func field(_ i: Int) -> String { i < f.count ? f[i] : "" }
        return EiBiRow(kHz: kHz, start: start, end: end, daysField: f[2], country: f[3], station: f[4], language: f[5],
                       target: f[6], site: field(7), persistence: Int(field(8)), startField: field(9), stopField: field(10))
    }

    /// Whether a days field is usable doesn't depend on the season.
    private static let probeSeason = EiBiSeason(year: 2026, half: .b)

    /// "HHMM-HHMM"; the end may be 2400.
    private static func times(_ text: String) -> (TimeOfDay, TimeOfDay)? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let a = Int(parts[0]), let b = Int(parts[1]),
              a / 100 < 24, a % 100 < 60, (b / 100 < 24 && b % 100 < 60) || b == 2400 else { return nil }
        return (TimeOfDay(hour: a / 100, minute: a % 100), TimeOfDay(hour: b / 100, minute: b % 100))
    }

    /// A start or stop field, "DDMM" (0401 is the 4th of January), as a date in the season's years: for `b`, September to
    /// December are in its year and the rest in the next. A "[…]" last-heard note, an empty or an impossible date is nil.
    public static func date(_ field: String, in season: EiBiSeason) -> ScheduleDate? {
        guard field.count == 4, field.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(field) else { return nil }
        let day = n / 100, month = n % 100
        let year = season.half == .a || month >= 9 ? season.year : season.year + 1
        guard (1...12).contains(month), let d = EiBi.utc.date(from: DateComponents(year: year, month: month, day: day)),
              EiBi.utc.component(.day, from: d) == day else { return nil }
        return ScheduleDate(year: year, month: month, day: day)
    }
}
