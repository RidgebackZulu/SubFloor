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

    public init(id: UUID = UUID(), name: String, frequencyHz: Double, mode: DemodMode, bandwidthHz: Double,
                upconverter: Bool = false, group: String? = nil, colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.bandwidthHz = bandwidthHz
        self.upconverter = upconverter
        self.group = group
        self.colorHex = colorHex
    }
}

private struct BookmarkFile: Codable {
    var version = 1
    var bookmarks: [Bookmark]
}

public final class BookmarkStore {
    public enum LoadResult: Equatable, Sendable { case loaded, createdDefaults, recoveredFromCorrupt }

    public let url: URL

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
            let aside = url.deletingLastPathComponent().appendingPathComponent("bookmarks.corrupt.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return (Self.defaults, .recoveredFromCorrupt)
        }
    }

    public func save(_ bookmarks: [Bookmark]) throws { try Self.write(bookmarks, to: url) }

    public static func write(_ bookmarks: [Bookmark], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(BookmarkFile(bookmarks: bookmarks)).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> [Bookmark] {
        try JSONDecoder().decode(BookmarkFile.self, from: Data(contentsOf: url)).bookmarks
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
    /// Keeps bookmarks whose name, group, mode, frequency or "hamitup" tag contain every whitespace-separated token.
    public static func filter(_ bookmarks: [Bookmark], query: String) -> [Bookmark] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return bookmarks }
        return bookmarks.filter { b in
            let haystack = [b.name, b.group ?? "", b.mode.rawValue, FrequencyFormatter.short(b.frequencyHz),
                            String(Int(b.frequencyHz)), b.upconverter ? "hamitup upconverter" : ""]
                .joined(separator: " ").lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }
}
