import Foundation

private struct ScheduleFile: Codable {
    var version = 1
    var schedules: [Schedule]
}

/// `schedules.json`: the owner's timed recordings. Modelled on `BookmarkStore`, including how a corrupt
/// file is kept aside rather than overwritten.
public final class ScheduleStore {
    public enum LoadResult: Equatable, Sendable {
        case loaded, createdDefaults, recoveredFromCorrupt
        /// The file was unreadable and could be neither moved nor copied aside; it was left where it was.
        case corruptNotPreserved
    }

    public static let maxSchedules = 200

    public let url: URL
    /// Where the unreadable file was preserved by the last `load` that returned `.recoveredFromCorrupt`.
    public private(set) var lastBackupURL: URL?

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SubFloor/schedules.json")
    }

    /// A missing or unreadable file gives the default pirate watch, switched off, in `localZone`.
    /// Rows that fail validation are dropped; a file whose every row is dropped loads as empty.
    public func load(localZone: String) -> ([Schedule], LoadResult) {
        let defaults = [Self.defaultWatch(localZone: localZone, now: Date())]
        guard FileManager.default.fileExists(atPath: url.path) else { return (defaults, .createdDefaults) }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(ScheduleFile.self, from: Data(contentsOf: url))
            return (file.schedules.filter(Self.isValid), .loaded)
        } catch {
            return (defaults, preserveCorrupt())
        }
    }

    public func save(_ schedules: [Schedule]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ScheduleFile(schedules: schedules)).write(to: url, options: .atomic)
    }

    public static func defaultWatch(localZone: String, now: Date) -> Schedule {
        Schedule(kind: .watch, name: "Pirates", lowHz: 6_900_000, highHz: 7_000_000, mode: .auto,
                 start: TimeOfDay(hour: 19, minute: 0), durationMinutes: 420, timeZone: localZone,
                 days: .weekly([.fr, .sa]), enabled: false, squelchMarginDb: 8, addedBy: nil,
                 source: .you, created: now)
    }

    private static func isValid(_ s: Schedule) -> Bool {
        switch s.kind {
        case .broadcast:
            return (1...8).contains(s.frequenciesHz.count) && s.frequenciesHz.allSatisfy(\.isFinite)
        case .watch:
            guard let low = s.lowHz, let high = s.highHz, low.isFinite, high.isFinite else { return false }
            return (10_000...400_000).contains(high - low)
        }
    }

    /// Moves the unreadable file to a fresh `schedules.corrupt-<timestamp>.json`, copying it if the move fails.
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
        var candidate = dir.appendingPathComponent("schedules.corrupt-\(stamp).json")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("schedules.corrupt-\(stamp)-\(n).json")
            n += 1
        }
        return candidate
    }
}
