import Foundation

/// The parts of a recording's file name (`RecordingNames.base` plus an extension): when its first sample was
/// taken, where it was tuned and what it holds. It is all a file made before the recording log existed has.
public struct RecordingFileName: Equatable, Sendable {
    public let start: Date            // second resolution, UTC
    public let frequencyHz: Double
    public let label: String          // "USB", "AM", "IQ"…
    public let fileExtension: String  // "wav", "flac", "m4a"…

    public init(start: Date, frequencyHz: Double, label: String, fileExtension: String) {
        self.start = start
        self.frequencyHz = frequencyHz
        self.label = label
        self.fileExtension = fileExtension
    }

    /// nil unless the name is `SubFloor_yyyyMMdd_HHmmssZ_<int>Hz_<LABEL>[_<n>].<ext>`. The `_<n>` is what
    /// `RecordingNames.unique` adds when a name is taken, and what a WAV recording that rolled carries.
    public static func parse(_ name: String) -> RecordingFileName? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = String(name[name.index(after: dot)...])
        let parts = name[..<dot].split(separator: "_", omittingEmptySubsequences: false)
        guard !ext.isEmpty, parts.count == 5 || parts.count == 6, parts[0] == "SubFloor",
              let start = date(day: parts[1], time: parts[2]),
              parts[3].hasSuffix("Hz"), let hz = Int(parts[3].dropLast(2)), parts[3].dropLast(2).allSatisfy(\.isASCII),
              !parts[4].isEmpty, parts[4].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        if parts.count == 6 { guard !parts[5].isEmpty, parts[5].allSatisfy(\.isASCII), Int(parts[5]) != nil else { return nil } }
        return RecordingFileName(start: start, frequencyHz: Double(hz), label: String(parts[4]), fileExtension: ext)
    }

    /// An audio recording: wav, flac or m4a, and a label other than "IQ". IQ captures are not for listening.
    public var isAudio: Bool {
        ["wav", "flac", "m4a"].contains(fileExtension.lowercased()) && label != "IQ"
    }

    /// Made once: a folder of a year of recordings is thousands of names, and a calendar per name was most of
    /// the cost of reading them.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `20261027` and `183219Z` as a UTC instant, or nil for anything that is not a real time.
    private static func date(day: Substring, time: Substring) -> Date? {
        guard day.count == 8, time.count == 7, time.hasSuffix("Z"),
              day.allSatisfy({ $0.isASCII && $0.isNumber }), time.dropLast().allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let d = day.compactMap(\.wholeNumberValue), t = time.dropLast().compactMap(\.wholeNumberValue)
        func n(_ a: [Int], _ r: Range<Int>) -> Int { a[r].reduce(0) { $0 * 10 + $1 } }
        let year = n(d, 0..<4), month = n(d, 4..<6), dom = n(d, 6..<8)
        let hour = n(t, 0..<2), minute = n(t, 2..<4), second = n(t, 4..<6)
        guard (1...12).contains(month), (1...31).contains(dom), hour < 24, minute < 60, second < 60 else { return nil }
        let calendar = utc
        let parts = DateComponents(year: year, month: month, day: dom, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: parts),
              calendar.dateComponents([.month, .day], from: date) == DateComponents(month: month, day: dom)   // not Feb 30 rolled over
        else { return nil }
        return date
    }
}

/// The recording being written now. The log has no `recording` entry for it until it ends, and the folder
/// listing may not show it yet, so the app passes what it knows.
public struct LiveRecording: Equatable, Sendable {
    public var file: String, start: Date, seconds: Double, frequencyHz: Double, mode: String, auto: Bool

    public init(file: String, start: Date, seconds: Double, frequencyHz: Double, mode: String, auto: Bool) {
        self.file = file
        self.start = start
        self.seconds = seconds
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.auto = auto
    }
}

public struct CatalogRecording: Equatable, Sendable, Identifiable {
    public var id: String { file }
    public let file: String
    public var start: Date
    public var seconds: Double?       // nil: no log entry and not measured yet
    public var frequencyHz: Double
    public var mode: String
    public var auto: Bool
    public var heard: Bool
    public var inProgress: Bool
    public var laneID: String         // "11175000 USB"

    public init(file: String, start: Date, seconds: Double?, frequencyHz: Double, mode: String, auto: Bool,
                heard: Bool, inProgress: Bool, laneID: String) {
        self.file = file
        self.start = start
        self.seconds = seconds
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.auto = auto
        self.heard = heard
        self.inProgress = inProgress
        self.laneID = laneID
    }
}

/// One row of the day timeline: a frequency and a mode.
public struct CatalogLane: Equatable, Sendable, Identifiable {
    public let id: String, frequencyHz: Double, mode: String, title: String
}

/// A squelch pop too short to record.
public struct CatalogPop: Hashable, Sendable {
    public let at: Date, seconds: Double, frequencyHz: Double, mode: String

    public init(at: Date, seconds: Double, frequencyHz: Double, mode: String) {
        self.at = at
        self.seconds = seconds
        self.frequencyHz = frequencyHz
        self.mode = mode
    }
}

/// What the Recordings window shows, merged from three sources that each know part of it: the folder
/// listing (which files exist), the day logs (when, how long, auto or manual, heard) and the recording in
/// progress. A pure value, so the merge rules are testable without a folder.
///
/// A recording's start, frequency, mode and auto flag come from the first source that has them: its
/// `recording` entry, its `autoStarted` entry (no length: it was cut short), then its file name (manual).
/// Only audio names in the listing are recordings, so a file deleted in Finder vanishes whatever the log
/// says. A recording belongs to the UTC day of its first sample, however long it runs.
///
/// The window asks for one day at a time, every second, of a folder that can hold a year of recordings, so
/// each file's day and unheard state are kept up to date as the sources change: a day's questions cost that
/// day's recordings, and the unheard count costs nothing.
public struct RecordingsCatalog: Equatable, Sendable {
    private struct Facts: Equatable, Sendable {
        var start: Date, frequencyHz: Double, mode: String
    }
    private struct Finished: Equatable, Sendable {
        var facts: Facts, seconds: Double, auto: Bool
    }

    private var names: [String: RecordingFileName] = [:]   // audio files in the listing
    private var listing: Set<String> = []
    private var finished: [String: Finished] = [:]         // from `recording` entries
    private var started: [String: Facts] = [:]             // from `autoStarted` entries
    private var heard: Set<String> = []
    /// A set, so a line applied twice (read back from the log after it was applied as written) is one pop.
    private var popsByDay: [Int: Set<CatalogPop>] = [:]
    private var measured: [String: Double] = [:]
    private var live: LiveRecording?
    /// The listed recordings (not the live one) by the UTC day they started on, and each one's day.
    private var filesByDay: [Int: Set<String>] = [:]
    private var dayOf: [String: Int] = [:]
    private var unheard: Set<String> = []

    public init(files: [String] = [], entries: [RecordingLogEntry] = [], live: LiveRecording? = nil) {
        // The log first and every file filed once after, rather than re-filing a file at each of its lines.
        apply(entries, refiling: false)
        self.live = live
        setFiles(files)
    }

    /// The folder listing, names only. Returns false, and changes nothing, when it is the listing already
    /// held; only names new to it are parsed.
    @discardableResult
    public mutating func setFiles(_ files: some Sequence<String>) -> Bool {
        let next = Set(files)
        guard next != listing else { return false }
        let gone = listing.subtracting(next), added = next.subtracting(listing)
        listing = next
        for file in gone where names.removeValue(forKey: file) != nil { refresh(file) }
        for file in added {
            guard let name = RecordingFileName.parse(file), name.isAudio else { continue }
            names[file] = name
            refresh(file)
        }
        return true
    }

    /// More log lines, in the order written. Applying a line again does not change the result, so a line
    /// that was applied as it was written and later read back from the log counts once.
    public mutating func apply(_ entries: [RecordingLogEntry]) { apply(entries, refiling: true) }

    private mutating func apply(_ entries: [RecordingLogEntry], refiling: Bool) {
        for entry in entries {
            switch entry {
            case .recording(let file, let start, let seconds, let frequencyHz, let mode, let auto):
                finished[file] = Finished(facts: Facts(start: start, frequencyHz: frequencyHz, mode: mode), seconds: seconds, auto: auto)
                if refiling { refresh(file) }
            case .autoStarted(let file, let start, let frequencyHz, let mode):
                started[file] = Facts(start: start, frequencyHz: frequencyHz, mode: mode)
                if refiling { refresh(file) }
            case .heard(let file, _):
                if heard.insert(file).inserted, refiling { refresh(file) }
            case .pop(let at, let seconds, let frequencyHz, let mode):
                popsByDay[Self.dayNumber(at), default: []].insert(CatalogPop(at: at, seconds: seconds, frequencyHz: frequencyHz, mode: mode))
            case .autoOff:
                break
            }
        }
    }

    public mutating func setLive(_ live: LiveRecording?) {
        let before = self.live?.file
        self.live = live
        for file in Set([before, live?.file].compactMap { $0 }) { refresh(file) }
    }

    /// The length of a file the log says nothing about, read from the file itself.
    public mutating func setMeasuredSeconds(_ seconds: Double, for file: String) { measured[file] = seconds }

    /// The day's recordings by start time. `day` is any instant in the UTC day.
    public func recordings(onUTCDay day: Date) -> [CatalogRecording] {
        let d = Self.dayNumber(day)
        var all = (filesByDay[d] ?? []).compactMap { file in
            file == live?.file ? nil : names[file].map { recording(file, $0) }   // the live one is added below, once
        }
        if let live, Self.dayNumber(live.start) == d { all.append(liveRecording(live)) }   // listed even before the folder shows it
        return all.sorted { ($0.start, $0.file) < ($1.start, $1.file) }
    }

    /// One lane per frequency and mode that has a recording on the day, lowest frequency first.
    public func lanes(onUTCDay day: Date) -> [CatalogLane] {
        var seen: Set<String> = []
        var lanes: [CatalogLane] = []
        for r in recordings(onUTCDay: day) where seen.insert(r.laneID).inserted {
            lanes.append(CatalogLane(id: r.laneID, frequencyHz: r.frequencyHz, mode: r.mode,
                                     title: Self.laneTitle(frequencyHz: r.frequencyHz, mode: r.mode)))
        }
        return lanes.sorted { ($0.frequencyHz, $0.mode) < ($1.frequencyHz, $1.mode) }
    }

    /// The day's ignored pops by time.
    public func pops(onUTCDay day: Date) -> [CatalogPop] {
        (popsByDay[Self.dayNumber(day)] ?? []).sorted { ($0.at, $0.frequencyHz, $0.mode, $0.seconds) < ($1.at, $1.frequencyHz, $1.mode, $1.seconds) }
    }

    public func recording(_ file: String) -> CatalogRecording? {
        if let live, live.file == file { return liveRecording(live) }
        guard let name = names[file] else { return nil }
        return recording(file, name)
    }

    /// Every name in the folder listing, audio or not.
    public var files: Set<String> { listing }

    /// Finished recordings the log has and the listener has not opened, by name.
    public var unheardFiles: [String] { unheard.sorted() }

    public var unheardCount: Int { unheard.count }

    /// `11.175 MHz USB`: MHz to three decimals, more (up to six) when the frequency needs them.
    public static func laneTitle(frequencyHz: Double, mode: String) -> String {
        var mhz = String(format: "%.6f", frequencyHz / 1_000_000)
        var extra = 3   // "%.6f" gives six decimals; trim up to three trailing zeros, so three stay
        while extra > 0, mhz.last == "0" { mhz.removeLast(); extra -= 1 }
        return "\(mhz) MHz \(mode)"
    }

    /// UTC midnight of the day holding `date`.
    public static func utcDayStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400)
    }

    /// The UTC day holding `date`, counted from 1970: the index key. Whole days of `Double`, so a date far out
    /// of range files under a day rather than trapping.
    private static func dayNumber(_ date: Date) -> Int {
        Int(exactly: (date.timeIntervalSince1970 / 86_400).rounded(.down)) ?? 0
    }

    /// Re-files `file` after any of its sources changed: its day, and whether it counts as unheard.
    private mutating func refresh(_ file: String) {
        if let old = dayOf.removeValue(forKey: file) {
            filesByDay[old]?.remove(file)
            if filesByDay[old]?.isEmpty == true { filesByDay[old] = nil }
        }
        guard let name = names[file] else {
            unheard.remove(file)
            return
        }
        let day = Self.dayNumber(facts(file, name).start)
        dayOf[file] = day
        filesByDay[day, default: []].insert(file)
        if file != live?.file && !heard.contains(file) && (finished[file] != nil || started[file] != nil) {
            unheard.insert(file)
        } else {
            unheard.remove(file)
        }
    }

    private func facts(_ file: String, _ name: RecordingFileName) -> Facts {
        finished[file]?.facts ?? started[file] ?? Facts(start: name.start, frequencyHz: name.frequencyHz, mode: name.label)
    }

    private func recording(_ file: String, _ name: RecordingFileName) -> CatalogRecording {
        let facts = facts(file, name), seconds: Double?, auto: Bool
        if let f = finished[file] {
            (seconds, auto) = (f.seconds, f.auto)
        } else {
            (seconds, auto) = (measured[file], started[file] != nil)
        }
        let logged = finished[file] != nil || started[file] != nil
        return CatalogRecording(file: file, start: facts.start, seconds: seconds, frequencyHz: facts.frequencyHz,
                                mode: facts.mode, auto: auto, heard: !logged || heard.contains(file), inProgress: false,
                                laneID: Self.laneID(facts.frequencyHz, facts.mode))
    }

    private func liveRecording(_ live: LiveRecording) -> CatalogRecording {
        CatalogRecording(file: live.file, start: live.start, seconds: live.seconds, frequencyHz: live.frequencyHz,
                         mode: live.mode, auto: live.auto, heard: false, inProgress: true,
                         laneID: Self.laneID(live.frequencyHz, live.mode))
    }

    /// `11175000 USB`. A frequency too large for an `Int` (a damaged log line) keeps its own lane rather
    /// than trapping.
    private static func laneID(_ frequencyHz: Double, _ mode: String) -> String {
        if let hz = Int(exactly: frequencyHz.rounded()) { return "\(hz) \(mode)" }
        return "\(frequencyHz) \(mode)"
    }
}
