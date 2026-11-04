import Foundation

extension EiBi {
    private static let names = ["Mo": Weekday.mo, "Tu": .tu, "We": .we, "Th": .th, "Fr": .fr, "Sa": .sa, "Su": .su]
    private static let months = ["Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
                                 "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12]
    /// Remarks in the days field that say how or whether it's on air, not which days. These four mark it irregular.
    private static let irregularFlags: Set<String> = ["irr", "tent", "test", "alt"]
    /// Other flags: sidebands and modes, spurs and the like (README: harm, imod, spur, Haj, Ram, USB, LSB, DRM).
    private static let plainFlags: Set<String> = ["usb", "lsb", "drm", "harm", "imod", "spur", "haj", "ram"]

    /// A days field as a schedule's days, in UTC. Anything that isn't a day form is a flag. `irr`, `tent`, `test`
    /// and `alt…` set `irregular`. Nil when the field has a token that is neither a day form nor a known flag.
    /// A field of only flags (or an empty one) is daily.
    public static func days(_ field: String, season: EiBiSeason) -> (days: ScheduleDays, irregular: Bool)? {
        var weekly = Set<Weekday>()
        var other: ScheduleDays?
        var irregular = false
        var forms = 0
        for token in field.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init) {
            let lower = token.lowercased()
            if irregularFlags.contains(lower) { irregular = true; continue }
            if plainFlags.contains(lower) { continue }
            if lower.hasPrefix("alt"), let set = weekdays(String(token.dropFirst(3))) {
                irregular = true; weekly.formUnion(set); forms += 1; continue
            }
            if let set = weekdays(token) { weekly.formUnion(set); forms += 1; continue }
            guard let parsed = single(token, season: season) else { return nil }
            other = parsed; forms += 1
        }
        if let other { return forms == 1 ? (other, irregular) : nil }
        return (.weekly(weekly.isEmpty ? Set(Weekday.allCases) : weekly), irregular)
    }

    /// "Mo", "Sa-Mo" (wraps), "SaSu", "1245".
    private static func weekdays(_ text: String) -> Set<Weekday>? {
        if !text.isEmpty, text.allSatisfy({ ("1"..."7").contains($0) }) {
            return Set(text.compactMap { Int(String($0)).flatMap(Weekday.init(rawValue:)) })
        }
        let ends = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if ends.count == 2, let a = names[ends[0]], let b = names[ends[1]] {
            var set: Set<Weekday> = [a]
            var d = a.rawValue
            while d != b.rawValue { d = d % 7 + 1; set.insert(Weekday(rawValue: d)!) }
            return set
        }
        guard ends.count == 1, text.count >= 2, text.count % 2 == 0 else { return nil }
        var set = Set<Weekday>()
        var rest = Substring(text)
        while !rest.isEmpty {
            guard let d = names[String(rest.prefix(2))] else { return nil }
            set.insert(d); rest = rest.dropFirst(2)
        }
        return set
    }

    /// "1.Sa", "Last7", "LastSa", "15Sep".
    private static func single(_ token: String, season: EiBiSeason) -> ScheduleDays? {
        func weekday(_ s: String) -> Weekday? {
            names[s] ?? (s.count == 1 ? Int(s).flatMap(Weekday.init(rawValue:)) : nil)
        }
        if token.hasPrefix("Last"), let wd = weekday(String(token.dropFirst(4))) { return .monthly(ordinal: -1, weekday: wd) }
        let dot = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if dot.count == 2, let n = Int(dot[0]), (1...5).contains(n), let wd = weekday(dot[1]) {
            return .monthly(ordinal: n, weekday: wd)
        }
        let digits = token.prefix { $0.isASCII && $0.isNumber }
        if (1...2).contains(digits.count), let day = Int(digits), let month = months[String(token.dropFirst(digits.count))] {
            let year = season.half == .a || month >= 9 ? season.year : season.year + 1
            guard let d = EiBi.utc.date(from: DateComponents(year: year, month: month, day: day)),
                  EiBi.utc.component(.day, from: d) == day else { return nil }
            return .once(ScheduleDate(year: year, month: month, day: day))
        }
        return nil
    }
}
