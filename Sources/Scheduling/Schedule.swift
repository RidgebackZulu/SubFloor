import Foundation

public enum ScheduleKind: String, Codable, Sendable { case broadcast, watch }

public enum ScheduleMode: String, Codable, Sendable, CaseIterable { case am, usb, lsb, auto }

/// EiBi's numbering: Monday = 1 … Sunday = 7.
public enum Weekday: Int, Codable, Sendable, CaseIterable, Comparable {
    case mo = 1, tu, we, th, fr, sa, su
    public static func < (a: Weekday, b: Weekday) -> Bool { a.rawValue < b.rawValue }
}

/// A wall-clock time in a schedule's zone.
public struct TimeOfDay: Codable, Hashable, Sendable {
    public var hour: Int      // 0…23
    public var minute: Int    // 0…59
    public init(hour: Int, minute: Int) { self.hour = hour; self.minute = minute }
}

/// A calendar date in a schedule's zone.
public struct ScheduleDate: Codable, Hashable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int
    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }
}

public enum ScheduleDays: Codable, Hashable, Sendable {
    case weekly(Set<Weekday>)                       // all seven = daily
    case monthly(ordinal: Int, weekday: Weekday)    // ordinal 1…5, or -1 for the last
    case once(ScheduleDate)
}

public enum ScheduleSource: String, Codable, Sendable { case timetable, agent, you }

/// Which EiBi row a timetable schedule came from.
public struct TimetableKey: Codable, Hashable, Sendable {
    public var station: String
    public var language: String
    public var season: String
    public init(station: String, language: String, season: String) {
        self.station = station; self.language = language; self.season = season
    }
}

public enum TimetableNote: Codable, Hashable, Sendable { case updated(Date), gone, irregular }

/// What the rest of the app needs to name a schedule.
public struct ScheduleTag: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public init(id: UUID, name: String) { self.id = id; self.name = name }
}

/// How a scheduled run ended.
public enum RunOutcome: Codable, Hashable, Sendable {
    case recorded(seconds: Double, files: Int)
    case nothingHeard(watch: Bool)
    case missedNoRSP
    case missedNotRunning
    case missedAsleep
    case stoppedByYou
    case overlapped(with: String)
    case rspLost(afterSeconds: Double)
    case lowDisk
    /// A broadcast with no floor on any of its frequencies: its squelch would have nothing to stand on.
    case noFloor

    /// The row's text. Minutes round to the nearest whole minute, 1 to 1,000,000 (clamped before `Int()`, which traps
    /// outside its range; NaN reads as 1).
    public var text: String {
        func minutes(_ seconds: Double) -> Int {
            let m = (seconds / 60).rounded()
            return m.isNaN ? 1 : Int(min(max(m, 1), 1_000_000))
        }
        switch self {
        case .recorded(let seconds, let files):
            return files > 1 ? "Recorded \(files) transmissions, \(minutes(seconds)) min" : "Recorded \(minutes(seconds)) min"
        case .nothingHeard(let watch): return watch ? "Nothing heard: no voice came on" : "Nothing heard: the squelch never opened"
        case .missedNoRSP: return "Missed: the RSP wasn't connected"
        case .missedNotRunning: return "Missed: SubFloor wasn't running"
        case .missedAsleep: return "Missed: the Mac was asleep"
        case .stoppedByYou: return "Stopped by you"
        case .overlapped(let name): return "Overlapped with \(name)"
        case .rspLost(let seconds): return "The RSP disconnected after \(minutes(seconds)) min"
        case .lowDisk: return "Stopped: less than 100 MB free"
        case .noFloor: return "Not recorded: no quiet spot to measure the noise floor"
        }
    }
}

public struct LastRun: Codable, Hashable, Sendable {
    public var outcome: RunOutcome
    public var at: Date
    public init(outcome: RunOutcome, at: Date) { self.outcome = outcome; self.at = at }
}

/// A timed recording: a broadcast on up to eight frequencies, or a watch over a band.
public struct Schedule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: ScheduleKind
    public var name: String
    public var frequenciesHz: [Double]       // broadcast: 1…8; watch: empty
    public var lowHz: Double?                // watch only
    public var highHz: Double?
    public var mode: ScheduleMode            // the caller's default: .am for broadcasts, .auto for watches
    public var start: TimeOfDay
    public var durationMinutes: Int
    public var timeZone: String              // "UTC" or an IANA id
    public var days: ScheduleDays
    public var startDate: ScheduleDate?      // inclusive, in `timeZone`
    public var endDate: ScheduleDate?
    public var timetableKey: TimetableKey?
    public var timetableNote: TimetableNote?
    public var enabled: Bool
    public var squelchMarginDb: Float
    public var addedBy: String?              // nil: the owner
    public var source: ScheduleSource
    public var created: Date
    public var lastRun: LastRun?

    public var tag: ScheduleTag { ScheduleTag(id: id, name: name) }

    public init(id: UUID = UUID(), kind: ScheduleKind, name: String, frequenciesHz: [Double] = [],
                lowHz: Double? = nil, highHz: Double? = nil, mode: ScheduleMode,
                start: TimeOfDay, durationMinutes: Int, timeZone: String, days: ScheduleDays,
                startDate: ScheduleDate? = nil, endDate: ScheduleDate? = nil,
                timetableKey: TimetableKey? = nil, timetableNote: TimetableNote? = nil,
                enabled: Bool = true, squelchMarginDb: Float = 8, addedBy: String? = nil,
                source: ScheduleSource = .you, created: Date, lastRun: LastRun? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.frequenciesHz = frequenciesHz
        self.lowHz = lowHz; self.highHz = highHz; self.mode = mode
        self.start = start; self.durationMinutes = durationMinutes; self.timeZone = timeZone; self.days = days
        self.startDate = startDate; self.endDate = endDate
        self.timetableKey = timetableKey; self.timetableNote = timetableNote
        self.enabled = enabled; self.squelchMarginDb = squelchMarginDb; self.addedBy = addedBy
        self.source = source; self.created = created; self.lastRun = lastRun
    }
}
