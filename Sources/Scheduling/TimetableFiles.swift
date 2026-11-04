import Foundation

/// How the timetable files are fetched (tests stub it; nothing else in this file touches the network).
public struct TimetableFetch: Sendable {
    /// Sends a request and returns its body and response.
    public var send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public init(send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) { self.send = send }

    /// `URLSession.shared`, 60 s timeout. A reply that isn't HTTP is an error.
    public static let live = TimetableFetch { request in
        var request = request
        request.timeoutInterval = 60
        request.setValue("SubFloor", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// What the cache folder remembers about the cached file and the last check (`meta.json`, ISO 8601 dates).
public struct TimetableMeta: Codable, Equatable, Sendable {
    public var season: String
    public var etag: String?
    public var lastModified: String?
    public var checkedAt: Date
    public var fetchedAt: Date?
}

/// The EiBi timetable on disk: the bundled file, a cached newer copy, and a weekly check for an update.
/// Files are `sked-<season>.csv` (the bytes as fetched) and `meta.json`. `meta` is guarded by a lock.
public final class TimetableFiles: @unchecked Sendable {
    public static let checkInterval: TimeInterval = 7 * 86_400
    /// A fetched file is used only if it has at least this many usable rows and at least half the rows of the one it replaces.
    public static let minimumRows = 1_000

    private let folder: URL
    private let fetch: TimetableFetch
    private let bundled: URL?
    private let lock = NSLock()
    private var storedMeta: TimetableMeta?

    /// The bundled `sked-b26.csv`.
    public static var bundledURL: URL? { Bundle.module.url(forResource: "sked-b26", withExtension: "csv", subdirectory: "Resources") }

    /// Application Support/SubFloor/timetable
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SubFloor", isDirectory: true).appendingPathComponent("timetable", isDirectory: true)
    }

    public init(folder: URL, fetch: TimetableFetch = .live, bundled: URL? = TimetableFiles.bundledURL) {
        self.folder = folder
        self.fetch = fetch
        self.bundled = bundled
        if let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            storedMeta = try? decoder.decode(TimetableMeta.self, from: data)
        }
    }

    public var meta: TimetableMeta? { lock.withLock { storedMeta } }

    /// The cached file if there is one, else the bundled one.
    public func load() -> Timetable {
        if let meta, let season = Self.season(named: meta.season),
           let data = try? Data(contentsOf: cacheURL(meta.season)) {
            return Timetable(data: data, season: season)
        }
        let (data, season) = bundledFile()
        return Timetable(data: data, season: season)
    }

    /// Due when there's no meta, the last check is older than `checkInterval`, or the current season has begun since the
    /// last check and isn't the cached one. Fetches the current season with If-None-Match / If-Modified-Since (only when
    /// that's the cached season). A 404 tries the previous season once. A 304 only stamps `checkedAt`. Returns the new
    /// timetable when one was accepted, else nil. A network error or a server error leaves `meta` alone, so the next
    /// launch retries.
    public func updateIfDue(now: Date) async -> Timetable? {
        let current = EiBiSeason.current(at: now)
        let old = meta
        if let old, now.timeIntervalSince(old.checkedAt) < Self.checkInterval,
           old.season == current.name || old.checkedAt >= current.startsAt { return nil }

        // What a fetched file must be at least half the size of.
        let cached = old.flatMap { m in (try? Data(contentsOf: cacheURL(m.season))).map { (m, $0) } }
        let (bundledBytes, bundledSeason) = bundledFile()
        let replacedRows = EiBi.parse(cached?.1 ?? bundledBytes).rows.count

        var seasons = [current]
        var index = 0
        while index < seasons.count {
            let season = seasons[index]
            index += 1
            var request = URLRequest(url: season.url)
            request.setValue("SubFloor", forHTTPHeaderField: "User-Agent")
            if let (m, _) = cached, m.season == season.name {
                if let etag = m.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                if let modified = m.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
            }
            guard let (body, response) = try? await fetch.send(request) else { return nil }
            switch response.statusCode {
            case 304:
                stamp(old, season: cached?.0.season ?? bundledSeason.name, now: now)
                return nil
            case 404:
                if seasons.count == 1 { seasons.append(season.previous) }
            case 200:
                let rows = EiBi.parse(body).rows.count
                guard rows >= Self.minimumRows, rows * 2 >= replacedRows else {
                    stamp(old, season: cached?.0.season ?? bundledSeason.name, now: now)
                    return nil
                }
                let newMeta = TimetableMeta(season: season.name, etag: response.value(forHTTPHeaderField: "ETag"),
                                            lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
                                            checkedAt: now, fetchedAt: now)
                guard store(body, meta: newMeta) else { return nil }
                if let old, old.season != season.name { try? FileManager.default.removeItem(at: cacheURL(old.season)) }
                return Timetable(data: body, season: season)
            default:
                return nil
            }
        }
        // Every season asked for was missing: the server replied, so the check counts.
        stamp(old, season: cached?.0.season ?? bundledSeason.name, now: now)
        return nil
    }

    // MARK: -

    private func cacheURL(_ season: String) -> URL { folder.appendingPathComponent("sked-\(season).csv") }

    /// The bundled file's bytes and season (from its name, `sked-b26`).
    private func bundledFile() -> (Data, EiBiSeason) {
        let data = bundled.flatMap { try? Data(contentsOf: $0) } ?? Timetable.bundledData()
        let name = bundled?.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "sked-", with: "") ?? "b26"
        return (data, Self.season(named: name) ?? EiBiSeason(year: 2026, half: .b))
    }

    /// "b26" is the winter season starting in 2026.
    static func season(named name: String) -> EiBiSeason? {
        guard name.count == 3, let half = EiBiSeason.Half(rawValue: String(name.prefix(1))), let yy = Int(name.suffix(2)) else { return nil }
        return EiBiSeason(year: 2000 + yy, half: half)
    }

    /// Records a check that got a reply but no new file: the old meta with `checkedAt` moved (or a bare one for `season`).
    private func stamp(_ old: TimetableMeta?, season: String, now: Date) {
        var meta = old ?? TimetableMeta(season: season, etag: nil, lastModified: nil, checkedAt: now, fetchedAt: nil)
        meta.checkedAt = now
        writeMeta(meta)
    }

    private func store(_ csv: Data, meta: TimetableMeta) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try csv.write(to: cacheURL(meta.season), options: .atomic)
        } catch { return false }
        writeMeta(meta)
        return true
    }

    private func writeMeta(_ meta: TimetableMeta) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        lock.withLock { storedMeta = meta }
        guard let data = try? encoder.encode(meta) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
    }
}
