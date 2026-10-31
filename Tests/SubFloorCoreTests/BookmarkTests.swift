import Testing
import Foundation
import DSPCore
@testable import SubFloorCore

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("subfloor-\(UUID())/bookmarks.json")
}

@Test func firstLoadCreatesDefaults() {
    let store = BookmarkStore(url: tempURL())
    let (bookmarks, result) = store.load()
    #expect(result == .createdDefaults)
    #expect(bookmarks == BookmarkStore.defaults)
    #expect(bookmarks.contains { $0.upconverter })
}

@Test func saveThenLoadRoundTrips() throws {
    let url = tempURL()
    let store = BookmarkStore(url: url)
    let b = Bookmark(name: "Test", frequencyHz: 7_074_000, mode: .usb, bandwidthHz: 2_700, upconverter: true, group: "G", colorHex: "#FF8800")
    try store.save([b])
    let (loaded, result) = BookmarkStore(url: url).load()
    #expect(result == .loaded)
    #expect(loaded == [b])
}

private func backupFiles(in dir: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter {
        $0.lastPathComponent.hasPrefix("bookmarks.corrupt-") && $0.lastPathComponent.hasSuffix(".json")
    }
}

@Test func corruptFileIsMovedAsideAndDefaultsRestored() throws {
    let url = tempURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ nope".utf8).write(to: url)
    let store = BookmarkStore(url: url)
    let (loaded, result) = store.load()
    #expect(result == .recoveredFromCorrupt)
    #expect(loaded == BookmarkStore.defaults)
    let backups = try backupFiles(in: url.deletingLastPathComponent())
    #expect(backups.count == 1)
    #expect(store.lastBackupURL?.lastPathComponent == backups.first?.lastPathComponent)
    #expect(try backups.map { try Data(contentsOf: $0) } == [Data("{ nope".utf8)])
}

@Test func repeatedCorruptionKeepsEveryBackup() throws {
    let url = tempURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ nope".utf8).write(to: url)
    #expect(BookmarkStore(url: url).load().1 == .recoveredFromCorrupt)
    try Data("{ second".utf8).write(to: url)
    #expect(BookmarkStore(url: url).load().1 == .recoveredFromCorrupt)
    let backups = try backupFiles(in: url.deletingLastPathComponent())
    #expect(backups.count == 2)
    #expect(Set(backups.map(\.path)).count == 2)
    let bodies = Set(try backups.map { try String(contentsOf: $0, encoding: .utf8) })
    #expect(bodies == ["{ nope", "{ second"])
}

@Test func unpreservableCorruptFileIsLeftInPlace() throws {
    let url = tempURL()
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{ nope".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
    let (loaded, result) = BookmarkStore(url: url).load()
    #expect(result == .corruptNotPreserved)
    #expect(loaded == BookmarkStore.defaults)
    #expect(try Data(contentsOf: url) == Data("{ nope".utf8))
}

@Test func searchMatchesAllTokensCaseInsensitively() {
    let names = BookmarkSearch.filter(BookmarkStore.defaults, query: "ft8 20").map(\.name)
    #expect(names == ["20m FT8"])
    #expect(BookmarkSearch.filter(BookmarkStore.defaults, query: "").count == BookmarkStore.defaults.count)
    #expect(BookmarkSearch.filter(BookmarkStore.defaults, query: "hamitup").allSatisfy { $0.upconverter })
}

@Test func searchOverHugeFrequencyBookmarkDoesNotCrash() {
    let b = Bookmark(name: "Huge", frequencyHz: 1e30, mode: .am, bandwidthHz: 1000)
    let n = Bookmark(name: "Nan", frequencyHz: .nan, mode: .am, bandwidthHz: 1000)
    #expect(BookmarkSearch.filter([b, n], query: "huge").count == 1)
}

@Test func readDropsInvalidBookmarks() throws {
    let url = tempURL()
    let good = Bookmark(name: "Good", frequencyHz: 7e6, mode: .usb, bandwidthHz: 2700)
    let bad = [Bookmark(name: "Big", frequencyHz: 1e30, mode: .usb, bandwidthHz: 2700),
               Bookmark(name: "Zero", frequencyHz: 0, mode: .usb, bandwidthHz: 2700),
               Bookmark(name: "Neg", frequencyHz: -5, mode: .usb, bandwidthHz: 2700),
               Bookmark(name: "BW", frequencyHz: 7e6, mode: .usb, bandwidthHz: 0),
               Bookmark(name: "BWBig", frequencyHz: 7e6, mode: .usb, bandwidthHz: 1e12)]
    try BookmarkStore.write([good] + bad, to: url)
    #expect(try BookmarkStore.read(from: url) == [good])
}

@Test func notesAgentAndDateRoundTrip() throws {
    let url = tempURL()
    let b = Bookmark(name: "Radio Ndarason", frequencyHz: 6_100_000, mode: .am, bandwidthHz: 8_000, group: "Broadcast",
                     notes: "Hausa, 0500–0600 UTC", addedBy: "Claude Code 2.1", created: Date(timeIntervalSince1970: 1_800_000_000))
    try BookmarkStore.write([b], to: url)
    #expect(try BookmarkStore.read(from: url) == [b])
}

@Test func bookmarksSavedBeforeNotesStillLoad() throws {
    let url = tempURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let old = """
    {"version":1,"bookmarks":[{"id":"00000000-0000-0000-0000-0000000000AA","name":"Old","frequencyHz":7074000,
    "mode":"usb","bandwidthHz":2700,"upconverter":false,"group":"HF Voice"}]}
    """
    try Data(old.utf8).write(to: url)
    let loaded = try BookmarkStore.read(from: url)
    #expect(loaded.count == 1)
    #expect(loaded[0].notes == nil && loaded[0].addedBy == nil && loaded[0].created == nil)
    #expect(loaded[0].group == "HF Voice")
}

@Test func groupNamesAreUniqueTrimmedAndSorted() {
    let bs = ["HF Voice", "digital", " Digital ", "hf voice", "", "Broadcast", "  "].map {
        Bookmark(name: "x", frequencyHz: 7_000_000, mode: .usb, bandwidthHz: 2_700, group: $0)
    } + [Bookmark(name: "y", frequencyHz: 7_000_000, mode: .usb, bandwidthHz: 2_700)]
    #expect(BookmarkGroups.names(bs) == ["Broadcast", "digital", "HF Voice"])
}

@Test func typedGroupJoinsAnExistingSpelling() {
    let existing = ["HF Voice", "Digital"]
    #expect(BookmarkGroups.normalized("hf voice", existing: existing) == "HF Voice")
    #expect(BookmarkGroups.normalized("  Pirates ", existing: existing) == "Pirates")
    #expect(BookmarkGroups.normalized("   ", existing: existing) == nil)
    #expect(BookmarkGroups.normalized(nil, existing: existing) == nil)
}

@Test func searchFindsNotesAndAgentBookmarks() {
    let mine = Bookmark(name: "A", frequencyHz: 6_925_000, mode: .usb, bandwidthHz: 2_700, notes: "pirate, plays rock")
    let agents = Bookmark(name: "B", frequencyHz: 4_625_000, mode: .usb, bandwidthHz: 2_700, addedBy: "Hermes 0.9")
    #expect(BookmarkSearch.filter([mine, agents], query: "rock") == [mine])
    #expect(BookmarkSearch.filter([mine, agents], query: "mcp") == [agents])
    #expect(BookmarkSearch.filter([mine, agents], query: "hermes") == [agents])
}
