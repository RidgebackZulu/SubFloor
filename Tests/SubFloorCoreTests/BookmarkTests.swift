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
    let (loaded, result) = BookmarkStore(url: url).load()
    #expect(result == .recoveredFromCorrupt)
    #expect(loaded == BookmarkStore.defaults)
    let backups = try backupFiles(in: url.deletingLastPathComponent())
    #expect(backups.count == 1)
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
