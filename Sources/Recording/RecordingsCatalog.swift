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

    /// `20261027` and `183219Z` as a UTC instant, or nil for anything that is not a real time.
    private static func date(day: Substring, time: Substring) -> Date? {
        guard day.count == 8, time.count == 7, time.hasSuffix("Z"),
              day.allSatisfy({ $0.isASCII && $0.isNumber }), time.dropLast().allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let d = day.compactMap(\.wholeNumberValue), t = time.dropLast().compactMap(\.wholeNumberValue)
        func n(_ a: [Int], _ r: Range<Int>) -> Int { a[r].reduce(0) { $0 * 10 + $1 } }
        let year = n(d, 0..<4), month = n(d, 4..<6), dom = n(d, 6..<8)
        let hour = n(t, 0..<2), minute = n(t, 2..<4), second = n(t, 4..<6)
        guard (1...12).contains(month), (1...31).contains(dom), hour < 24, minute < 60, second < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
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
public struct CatalogPop: Equatable, Sendable {
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
    private var pops: [CatalogPop] = []
    private var measured: [String: Double] = [:]
    private var live: LiveRecording?

    public init(files: [String] = [], entries: [RecordingLogEntry] = [], live: LiveRecording? = nil) {
        setFiles(files)
        apply(entries)
        self.live = live
    }

    /// The folder listing, names only.
    public mutating func setFiles(_ files: [String]) {
        listing = Set(files)
        names = [:]
        for file in files {
            if let name = RecordingFileName.parse(file), name.isAudio { names[file] = name }
        }
    }

    /// More log lines, in the order written. Applying a line twice does not change the result, except that a
    /// pop is listed twice, so give each line once.
    public mutating func apply(_ entries: [RecordingLogEntry]) {
        for entry in entries {
            switch entry {
            case .recording(let file, let start, let seconds, let frequencyHz, let mode, let auto):
                finished[file] = Finished(facts: Facts(start: start, frequencyHz: frequencyHz, mode: mode), seconds: seconds, auto: auto)
            case .autoStarted(let file, let start, let frequencyHz, let mode):
                started[file] = Facts(start: start, frequencyHz: frequencyHz, mode: mode)
            case .heard(let file, _):
                heard.insert(file)
            case .pop(let at, let seconds, let frequencyHz, let mode):
                pops.append(CatalogPop(at: at, seconds: seconds, frequencyHz: frequencyHz, mode: mode))
            case .autoOff:
                break
            }
        }
    }

    public mutating func setLive(_ live: LiveRecording?) { self.live = live }

    /// The length of a file the log says nothing about, read from the file itself.
    public mutating func setMeasuredSeconds(_ seconds: Double, for file: String) { measured[file] = seconds }

    /// The day's recordings by start time. `day` is any instant in the UTC day.
    public func recordings(onUTCDay day: Date) -> [CatalogRecording] {
        let start = Self.utcDayStart(day)
        let end = start.addingTimeInterval(86_400)
        return allRecordings().filter { $0.start >= start && $0.start < end }
            .sorted { ($0.start, $0.file) < ($1.start, $1.file) }
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
        let start = Self.utcDayStart(day)
        let end = start.addingTimeInterval(86_400)
        return pops.filter { $0.at >= start && $0.at < end }.sorted { $0.at < $1.at }
    }

    public func recording(_ file: String) -> CatalogRecording? {
        if let live, live.file == file { return liveRecording(live) }
        guard let name = names[file] else { return nil }
        return recording(file, name)
    }

    /// Every name in the folder listing, audio or not.
    public var files: Set<String> { listing }

    /// Finished recordings the log has and the listener has not opened, by name.
    public var unheardFiles: [String] {
        names.keys.filter { file in
            file != live?.file && !heard.contains(file) && (finished[file] != nil || started[file] != nil)
        }.sorted()
    }

    public var unheardCount: Int { unheardFiles.count }

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

    private func allRecordings() -> [CatalogRecording] {
        var all = names.compactMap { file, name in file == live?.file ? nil : recording(file, name) }
        if let live { all.append(liveRecording(live)) }   // listed even before the folder shows it
        return all
    }

    private func recording(_ file: String, _ name: RecordingFileName) -> CatalogRecording {
        let facts: Facts, seconds: Double?, auto: Bool
        if let f = finished[file] {
            (facts, seconds, auto) = (f.facts, f.seconds, f.auto)
        } else if let s = started[file] {
            (facts, seconds, auto) = (s, measured[file], true)
        } else {
            facts = Facts(start: name.start, frequencyHz: name.frequencyHz, mode: name.label)
            (seconds, auto) = (measured[file], false)
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

    private static func laneID(_ frequencyHz: Double, _ mode: String) -> String {
        "\(Int(frequencyHz.rounded())) \(mode)"
    }
}
