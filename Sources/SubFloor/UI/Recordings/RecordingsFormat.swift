import Foundation

/// How the Recordings window writes times, lengths and days. Always UTC, like the file names and the log, and
/// always in English digits and names whatever the Mac's locale, so the window reads like an HF log.
enum RecordingsFormat {
    /// `07:48:12.4Z`: the UTC time of day to a tenth of a second. Tenths are truncated, not rounded, so the
    /// clock never shows a moment that has not happened yet (23:59:59.99 is still 23:59:59.9, not 00:00:00.0).
    static func clock(_ date: Date) -> String {
        // A hair added before truncating: 19.4 s stored as 19.39999… must still read .4.
        let tenths = Int((date.timeIntervalSince1970 * 10 + 1e-3).rounded(.down))
        let ofDay = ((tenths % 864_000) + 864_000) % 864_000
        let seconds = ofDay / 10
        return String(format: "%02d:%02d:%02d.%dZ", seconds / 3600, seconds / 60 % 60, seconds % 60, ofDay % 10)
    }

    /// `18:32:19Z`: the clock to the second, for a recording's start.
    static func time(_ date: Date) -> String {
        String(clock(date).dropLast(3)) + "Z"
    }

    /// `7.8 s`, `48 s`, `3 min 47 s`, `1 h 12 min`: a tenth under ten seconds, where a squelch break is a
    /// matter of tenths, and coarser as recordings get longer.
    static func length(_ seconds: Double) -> String {
        // Kept within what an `Int` holds: a damaged log line's length must not trap the hover.
        let s = seconds.isFinite ? min(max(seconds, 0), 1e12) : 0
        let tenths = (s * 10).rounded()
        if tenths < 100 { return String(format: "%.1f s", tenths / 10) }
        let total = Int(s.rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 {
            let (m, sec) = (total / 60, total % 60)
            return sec == 0 ? "\(m) min" : "\(m) min \(sec) s"
        }
        let minutes = Int((s / 60).rounded())
        let (h, m) = (minutes / 60, minutes % 60)
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// `Tue 27 Oct 2026 UTC`.
    static func dayTitle(_ dayStart: Date) -> String {
        let c = utc.dateComponents([.weekday, .day, .month, .year], from: dayStart)
        let weekday = weekdays[(c.weekday ?? 1) - 1], month = months[(c.month ?? 1) - 1]
        return "\(weekday) \(c.day ?? 1) \(month) \(c.year ?? 1970) UTC"
    }

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
