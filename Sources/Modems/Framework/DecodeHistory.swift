import Foundation

/// One FT8/WSPR message heard, with the callsigns and grid parsed out of it.
public struct HeardDecode: Codable, Equatable, Sendable {
    /// The slot's start (UTC).
    public var time: Date
    /// `ModeID.rawValue`.
    public var mode: String
    public var rfHz: Double
    public var audioHz: Double
    public var snrDb: Float
    public var message: String
    /// `SlotMessage.Kind.rawValue`.
    public var kind: String
    public var from: String?
    public var to: String?
    public var grid: String?
    /// The grid's centre.
    public var lat: Double?
    public var lon: Double?

    /// `rfHz` is the decode's RF frequency (the decode itself only knows its audio frequency).
    public static func from(_ d: SlotDecode, rfHz: Double) -> HeardDecode {
        let parsed = SlotMessage.parse(d.message, mode: d.mode)
        let centre = parsed.grid.flatMap(Maidenhead.center)
        return HeardDecode(time: d.slotStart, mode: d.mode.rawValue, rfHz: rfHz, audioHz: d.frequencyHz, snrDb: d.snrDb,
                           message: d.message, kind: parsed.kind.rawValue, from: parsed.from, to: parsed.to,
                           grid: parsed.grid, lat: centre?.lat, lon: centre?.lon)
    }
}

/// One station heard: the roll-up of its decodes.
public struct HeardStation: Equatable, Sendable {
    public var call: String
    /// From the latest decode that carried one.
    public var grid: String?
    public var lat: Double?
    public var lon: Double?
    public var bestSnrDb: Float
    public var lastHeard: Date
    public var count: Int
    /// In the order first heard.
    public var bands: [String]
}

/// The amateur bands.
public enum BandPlan {
    private static let bands: [(name: String, range: ClosedRange<Double>)] = [
        ("160m", 1_800_000...2_000_000), ("80m", 3_500_000...4_000_000), ("60m", 5_250_000...5_450_000),
        ("40m", 7_000_000...7_300_000), ("30m", 10_100_000...10_150_000), ("20m", 14_000_000...14_350_000),
        ("17m", 18_068_000...18_168_000), ("15m", 21_000_000...21_450_000), ("12m", 24_890_000...24_990_000),
        ("10m", 28_000_000...29_700_000), ("6m", 50_000_000...54_000_000), ("2m", 144_000_000...148_000_000),
        ("70cm", 420_000_000...450_000_000),
    ]

    /// "160m" … "70cm"; nil outside the amateur bands.
    public static func name(forHz hz: Double) -> String? {
        bands.first { $0.range.contains(hz) }?.name
    }
}

/// Thirty days of decoded FT8/WSPR messages, kept one JSON line per decode in a file per UTC day
/// (`2026-10-01.jsonl`). The last 168 hours are held in memory, loaded on first use; older queries
/// read the day files. All state belongs to a private serial queue: `append` only enqueues (it is
/// called from the main thread and never waits on file I/O); queries wait for the queue.
public final class DecodeHistory: @unchecked Sendable {
    private static let recentWindow: TimeInterval = 168 * 3_600

    private let folder: URL
    private let keepDays: Int
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "SubFloor.DecodeHistory")
    // Queue only from here.
    private var recent: [HeardDecode] = []
    private var recentLoaded = false
    /// The UTC day number of the last prune.
    private var prunedDay: Int?

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SubFloor/decodes")
    }

    public init(folder: URL, keepDays: Int = 30, now: @escaping @Sendable () -> Date = Date.init) {
        self.folder = folder
        self.keepDays = keepDays
        self.now = now
        queue.async { self.pruneIfNewDay() }
    }

    public func append(_ decodes: [HeardDecode]) {
        guard !decodes.isEmpty else { return }
        queue.async {
            self.write(decodes)
            guard self.recentLoaded else { return }   // the file has them for the load
            let cutoff = self.now().addingTimeInterval(-Self.recentWindow)
            self.recent.removeAll { $0.time < cutoff }
            self.recent.append(contentsOf: decodes.filter { $0.time >= cutoff })
        }
    }

    /// Newest first.
    public func decodes(since: Date, until: Date = .distantFuture, mode: String? = nil) -> [HeardDecode] {
        let found: [HeardDecode] = queue.sync {
            let t = now()
            let cutoff = t.addingTimeInterval(-Self.recentWindow)
            guard since >= cutoff else { return readDays(from: since, to: min(until, t)) }
            if !recentLoaded {
                recent = readDays(from: cutoff, to: t)
                recentLoaded = true
            }
            return recent
        }
        return found.filter { $0.time >= since && $0.time <= until && (mode == nil || $0.mode == mode) }
            .enumerated().sorted { ($0.element.time, $1.offset) > ($1.element.time, $0.offset) }.map(\.element)
    }

    /// One row per sender heard since `since` (in one mode, or any), most recently heard first.
    public func stations(since: Date, mode: String? = nil) -> [HeardStation] {
        var byCall: [String: HeardStation] = [:]
        for d in decodes(since: since, mode: mode).reversed() {
            guard let call = d.from else { continue }
            let band = BandPlan.name(forHz: d.rfHz)
            if var s = byCall[call] {
                s.bestSnrDb = max(s.bestSnrDb, d.snrDb)
                s.lastHeard = d.time
                s.count += 1
                if let band, !s.bands.contains(band) { s.bands.append(band) }
                if d.grid != nil { (s.grid, s.lat, s.lon) = (d.grid, d.lat, d.lon) }
                byCall[call] = s
            } else {
                byCall[call] = HeardStation(call: call, grid: d.grid, lat: d.lat, lon: d.lon, bestSnrDb: d.snrDb,
                                            lastHeard: d.time, count: 1, bands: band.map { [$0] } ?? [])
            }
        }
        return byCall.values.sorted { ($0.lastHeard, $1.call) > ($1.lastHeard, $0.call) }
    }

    /// Waits for pending writes (tests).
    public func flush() { queue.sync {} }

    // MARK: Files (queue)

    private func dayName(_ date: Date) -> String {
        let c = Self.utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func dayStart(ofFile name: String) -> Date? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let parts = name.dropLast(6).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Self.utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func write(_ decodes: [HeardDecode]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        pruneIfNewDay()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var lines: [String: Data] = [:]
        for d in decodes {
            guard var line = try? encoder.encode(d) else { continue }
            line.append(0x0A)
            lines[dayName(d.time), default: Data()].append(line)
        }
        for (day, data) in lines {
            let url = folder.appendingPathComponent("\(day).jsonl")
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Reads the day files that can hold `from...to`. Unreadable lines are skipped.
    private func readDays(from: Date, to: Date) -> [HeardDecode] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var result: [HeardDecode] = []
        for name in names.sorted() {
            guard let start = dayStart(ofFile: name), start.addingTimeInterval(86_400) > from, start <= to,
                  let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { continue }
            for line in data.split(separator: 0x0A) {
                if let d = try? decoder.decode(HeardDecode.self, from: line) { result.append(d) }
            }
        }
        return result
    }

    /// Deletes the day files that end more than `keepDays` before now, once per UTC day.
    private func pruneIfNewDay() {
        let t = now()
        let day = Int((t.timeIntervalSince1970 / 86_400).rounded(.down))
        guard prunedDay != day else { return }
        prunedDay = day
        let oldest = t.addingTimeInterval(-Double(keepDays) * 86_400)
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            if let start = dayStart(ofFile: name), start.addingTimeInterval(86_400) <= oldest {
                try? fm.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }
}
