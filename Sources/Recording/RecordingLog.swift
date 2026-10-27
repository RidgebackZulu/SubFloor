import Foundation

/// One line of the recording log. On disk each entry is a flat JSON object with a `type`:
///
///     {"auto":true,"file":"SubFloor_20261026_143000Z_146520000Hz_NFM.wav","frequencyHz":146520000,"mode":"NFM","seconds":12.5,"start":"2026-10-26T14:30:00.250Z","type":"recording"}
///
/// Dates are ISO 8601 UTC with milliseconds. `file` is a file name only, never a path, so the
/// recordings folder can move.
public enum RecordingLogEntry: Codable, Equatable, Sendable {
    /// A finished recording, auto or manual. `start` is the time of its first sample.
    case recording(file: String, start: Date, seconds: Double, frequencyHz: Double, mode: String, auto: Bool)
    /// A squelch pop too short to record.
    case pop(at: Date, seconds: Double, frequencyHz: Double, mode: String)
    /// The listener opened a recording. Written by the recordings window; defined here so the format is fixed.
    case heard(file: String, at: Date)
    /// An auto recording has begun writing `file`, whose first sample is at `start`. Its `.recording`
    /// entry follows when it ends; one without (a crash, a force-quit) is a recording cut short.
    case autoStarted(file: String, start: Date, frequencyHz: Double, mode: String)
    /// Auto-record turned itself off, and why (low disk).
    case autoOff(at: Date, reason: String)

    /// What the entry is filed under: a recording's start, or the entry's `at`.
    public var date: Date {
        switch self {
        case .recording(_, let start, _, _, _, _): start
        case .pop(let at, _, _, _): at
        case .heard(_, let at): at
        case .autoStarted(_, let start, _, _): start
        case .autoOff(let at, _): at
        }
    }

    private enum Kind: String, Codable { case recording, pop, heard, autoStarted, autoOff }

    private enum Keys: String, CodingKey {
        case type, file, start, at, seconds, frequencyHz, mode, auto, reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .recording:
            self = .recording(
                file: try c.decode(String.self, forKey: .file),
                start: try Self.decodeDate(c, .start),
                seconds: try c.decode(Double.self, forKey: .seconds),
                frequencyHz: try c.decode(Double.self, forKey: .frequencyHz),
                mode: try c.decode(String.self, forKey: .mode),
                auto: try c.decode(Bool.self, forKey: .auto))
        case .pop:
            self = .pop(
                at: try Self.decodeDate(c, .at),
                seconds: try c.decode(Double.self, forKey: .seconds),
                frequencyHz: try c.decode(Double.self, forKey: .frequencyHz),
                mode: try c.decode(String.self, forKey: .mode))
        case .heard:
            self = .heard(file: try c.decode(String.self, forKey: .file), at: try Self.decodeDate(c, .at))
        case .autoStarted:
            self = .autoStarted(
                file: try c.decode(String.self, forKey: .file),
                start: try Self.decodeDate(c, .start),
                frequencyHz: try c.decode(Double.self, forKey: .frequencyHz),
                mode: try c.decode(String.self, forKey: .mode))
        case .autoOff:
            self = .autoOff(at: try Self.decodeDate(c, .at), reason: try c.decode(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .recording(let file, let start, let seconds, let frequencyHz, let mode, let auto):
            try c.encode(Kind.recording, forKey: .type)
            try c.encode(file, forKey: .file)
            try c.encode(Self.format.format(start), forKey: .start)
            try c.encode(seconds, forKey: .seconds)
            try c.encode(frequencyHz, forKey: .frequencyHz)
            try c.encode(mode, forKey: .mode)
            try c.encode(auto, forKey: .auto)
        case .pop(let at, let seconds, let frequencyHz, let mode):
            try c.encode(Kind.pop, forKey: .type)
            try c.encode(Self.format.format(at), forKey: .at)
            try c.encode(seconds, forKey: .seconds)
            try c.encode(frequencyHz, forKey: .frequencyHz)
            try c.encode(mode, forKey: .mode)
        case .heard(let file, let at):
            try c.encode(Kind.heard, forKey: .type)
            try c.encode(file, forKey: .file)
            try c.encode(Self.format.format(at), forKey: .at)
        case .autoStarted(let file, let start, let frequencyHz, let mode):
            try c.encode(Kind.autoStarted, forKey: .type)
            try c.encode(file, forKey: .file)
            try c.encode(Self.format.format(start), forKey: .start)
            try c.encode(frequencyHz, forKey: .frequencyHz)
            try c.encode(mode, forKey: .mode)
        case .autoOff(let at, let reason):
            try c.encode(Kind.autoOff, forKey: .type)
            try c.encode(Self.format.format(at), forKey: .at)
            try c.encode(reason, forKey: .reason)
        }
    }

    /// `2026-10-26T14:30:00.250Z`. The style is UTC by default.
    private static let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func decodeDate(_ c: KeyedDecodingContainer<Keys>, _ key: Keys) throws -> Date {
        let text = try c.decode(String.self, forKey: key)
        do { return try format.parse(text) } catch {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "not an ISO 8601 date: \(text)")
        }
    }
}

/// An append-only log of recordings, ignored pops and auto-record events, one JSON-lines file per UTC day in
/// `<recordings folder>/.subfloor/yyyy-MM-dd.jsonl`. An entry is filed under the UTC day of its
/// `date`, so a recording that runs past midnight stays with the day it started.
public struct RecordingLog: Sendable {
    private let directory: URL

    /// `folder` is the recordings folder; the log lives in `folder/.subfloor/`.
    public init(folder: URL) {
        directory = folder.appendingPathComponent(".subfloor", isDirectory: true)
    }

    public func fileURL(forUTCDay day: Date) -> URL {
        directory.appendingPathComponent(Self.dayName(day)).appendingPathExtension("jsonl")
    }

    /// Adds one line per entry to the file of its UTC day, creating `.subfloor/` and the file as needed.
    public func append(_ entries: [RecordingLogEntry]) throws {
        guard !entries.isEmpty else { return }
        var days: [String: [RecordingLogEntry]] = [:]
        var order: [String] = []
        for entry in entries {
            let name = Self.dayName(entry.date)
            if days[name] == nil { order.append(name) }
            days[name, default: []].append(entry)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for name in order {
            var data = Data()
            for entry in days[name] ?? [] {
                data.append(try encoder.encode(entry))
                data.append(0x0A)
            }
            try Self.append(data, to: directory.appendingPathComponent(name).appendingPathExtension("jsonl"))
        }
    }

    /// The day's entries in the order written; lines that do not decode are skipped, and a day with no file is empty.
    public func entries(forUTCDay day: Date) throws -> [RecordingLogEntry] {
        let url = fileURL(forUTCDay: day)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        return try Data(contentsOf: url).split(separator: 0x0A).compactMap { line in
            try? decoder.decode(RecordingLogEntry.self, from: Data(line))
        }
    }

    private static func append(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: data) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            return
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var out = data
        if end > 0 {   // a torn last line (a crash mid-write) must not swallow the first new one
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { out.insert(0x0A, at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: out)
    }

    private static func dayName(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
