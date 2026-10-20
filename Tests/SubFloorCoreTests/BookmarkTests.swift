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

@Test func corruptFileIsMovedAsideAndDefaultsRestored() throws {
    let url = tempURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ nope".utf8).write(to: url)
    let (loaded, result) = BookmarkStore(url: url).load()
    #expect(result == .recoveredFromCorrupt)
    #expect(loaded == BookmarkStore.defaults)
    let corrupt = url.deletingLastPathComponent().appendingPathComponent("bookmarks.corrupt.json")
    #expect(FileManager.default.fileExists(atPath: corrupt.path))
}

@Test func searchMatchesAllTokensCaseInsensitively() {
    let names = BookmarkSearch.filter(BookmarkStore.defaults, query: "ft8 20").map(\.name)
    #expect(names == ["20m FT8"])
    #expect(BookmarkSearch.filter(BookmarkStore.defaults, query: "").count == BookmarkStore.defaults.count)
    #expect(BookmarkSearch.filter(BookmarkStore.defaults, query: "hamitup").allSatisfy { $0.upconverter })
}
