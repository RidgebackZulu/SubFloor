import DSPCore
import Foundation

public struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var frequencyHz: Double
    public var mode: DemodMode
    public var bandwidthHz: Double
    public var upconverter: Bool
    public var group: String?
    public var colorHex: String?
    /// Free text: what was heard, schedule, modulation details.
    public var notes: String?
    /// The AI agent that saved it through the MCP server ("Claude Code 2.1"); nil when saved by hand.
    public var addedBy: String?
    /// When it was saved (nil for bookmarks from before this was kept).
    public var created: Date?

    public init(id: UUID = UUID(), name: String, frequencyHz: Double, mode: DemodMode, bandwidthHz: Double,
                upconverter: Bool = false, group: String? = nil, colorHex: String? = nil, notes: String? = nil,
                addedBy: String? = nil, created: Date? = nil) {
        self.id = id
        self.name = name
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.bandwidthHz = bandwidthHz
        self.upconverter = upconverter
        self.group = group
        self.colorHex = colorHex
        self.notes = notes
        self.addedBy = addedBy
        self.created = created
    }

    /// Saved by an AI agent through the MCP server.
    public var isFromAgent: Bool { addedBy != nil }
}

public enum BookmarkGroups {
    /// The groups in use, each once (case-insensitively, keeping the first spelling), sorted.
    public static func names(_ bookmarks: [Bookmark]) -> [String] {
        var seen = Set<String>(), names: [String] = []
        for b in bookmarks {
            guard let g = b.group?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty,
                  seen.insert(g.lowercased()).inserted else { continue }
            names.append(g)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// `typed` as a group: trimmed, nil when empty, and spelled like an existing group that matches
    /// it case-insensitively (so "hf voice" joins "HF Voice" rather than starting a second group).
    public static func normalized(_ typed: String?, existing: [String]) -> String? {
        guard let t = typed?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return existing.first { $0.caseInsensitiveCompare(t) == .orderedSame } ?? t
    }
}

private struct BookmarkFile: Codable {
    var version = 1
    var bookmarks: [Bookmark]
}

public final class BookmarkStore {
    public enum LoadResult: Equatable, Sendable {
        case loaded, createdDefaults, recoveredFromCorrupt
        /// The file was unreadable and could be neither moved nor copied aside; it was left where it was.
        case corruptNotPreserved
    }

    public let url: URL
    /// Where the unreadable file was preserved by the last `load()` that returned `.recoveredFromCorrupt`.
    public private(set) var lastBackupURL: URL?

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SubFloor/bookmarks.json")
    }

    public func load() -> ([Bookmark], LoadResult) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (Self.defaults, .createdDefaults) }
        do {
            return (try Self.read(from: url), .loaded)
        } catch {
            return (Self.defaults, preserveCorrupt())
        }
    }

    /// Moves the unreadable file to a fresh `bookmarks.corrupt-<timestamp>.json`, copying it if the move fails.
    /// Existing backups are never overwritten or deleted.
    private func preserveCorrupt() -> LoadResult {
        let backup = uniqueBackupURL()
        lastBackupURL = nil
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            lastBackupURL = backup
            return .recoveredFromCorrupt
        } catch {
            do {
                try FileManager.default.copyItem(at: url, to: backup)
                lastBackupURL = backup
                return .recoveredFromCorrupt
            } catch {
                return .corruptNotPreserved
            }
        }
    }

    private func uniqueBackupURL() -> URL {
        let dir = url.deletingLastPathComponent()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var candidate = dir.appendingPathComponent("bookmarks.corrupt-\(stamp).json")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("bookmarks.corrupt-\(stamp)-\(n).json")
            n += 1
        }
        return candidate
    }

    public func save(_ bookmarks: [Bookmark]) throws { try Self.write(bookmarks, to: url) }

    public static func write(_ bookmarks: [Bookmark], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(BookmarkFile(bookmarks: bookmarks)).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> [Bookmark] {
        let all = try JSONDecoder().decode(BookmarkFile.self, from: Data(contentsOf: url)).bookmarks
        func valid(_ v: Double) -> Bool { v.isFinite && v > 0 && v <= FrequencyParser.maxHz }
        return all.filter { valid($0.frequencyHz) && valid($0.bandwidthHz) }
    }

    public static let defaults: [Bookmark] = [
        Bookmark(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "WWV 10 MHz", frequencyHz: 10_000_000, mode: .am, bandwidthHz: 8_000, group: "Time"),
        Bookmark(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "20m FT8", frequencyHz: 14_074_000, mode: .usb, bandwidthHz: 2_700, group: "Digital"),
        Bookmark(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "40m FT8", frequencyHz: 7_074_000, mode: .usb, bandwidthHz: 2_700, group: "Digital"),
        Bookmark(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, name: "20m CW", frequencyHz: 14_030_000, mode: .cw, bandwidthHz: 500, group: "CW"),
        Bookmark(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, name: "2m APRS", frequencyHz: 144_390_000, mode: .nfm, bandwidthHz: 12_500, group: "VHF"),
        Bookmark(id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, name: "FM Broadcast 98.1", frequencyHz: 98_100_000, mode: .wfm, bandwidthHz: 180_000, group: "Broadcast"),
        Bookmark(id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!, name: "40m SSB (HamItUp)", frequencyHz: 7_200_000, mode: .lsb, bandwidthHz: 2_700, upconverter: true, group: "HF via HamItUp", colorHex: "#FF9F43"),
    ]
}

public enum BookmarkSearch {
    /// Keeps bookmarks whose name, group, notes, mode, frequency, "hamitup" tag or "mcp"/agent tag
    /// contain every whitespace-separated token.
    public static func filter(_ bookmarks: [Bookmark], query: String) -> [Bookmark] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return bookmarks }
        return bookmarks.filter { b in
            let haystack = [b.name, b.group ?? "", b.notes ?? "", b.mode.rawValue, FrequencyFormatter.short(b.frequencyHz),
                            String(FrequencyFormatter.safeInt(b.frequencyHz)), b.upconverter ? "hamitup upconverter" : "",
                            b.addedBy.map { "mcp agent \($0)" } ?? ""]
                .joined(separator: " ").lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }
}
