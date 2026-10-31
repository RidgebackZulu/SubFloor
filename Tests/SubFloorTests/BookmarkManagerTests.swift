import DSPCore
import Foundation
import SubFloorCore
import Testing
@testable import SubFloor

@MainActor
struct BookmarkManagerTests {
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SubFloorTests-\(UUID().uuidString)/bookmarks.json")

    private func makeModel() -> AppModel {
        AppModel(bookmarkStore: BookmarkStore(url: url),
                        defaults: UserDefaults(suiteName: UUID().uuidString)!,
                        openRSP: { throw CancellationError() }, rspOpenTimeout: .seconds(10))
    }

    @Test func addingJoinsAnExistingGroupAndStampsTheDate() throws {
        let m = makeModel()
        let id = m.addBookmark(Bookmark(name: "x", frequencyHz: 7_074_000, mode: .usb, bandwidthHz: 2_700, group: " digital "))
        let b = try #require(m.bookmarks.first { $0.id == id })
        #expect(b.group == "Digital")   // a default group
        #expect(b.created != nil)
        // Saved: a fresh model reads it back.
        let (saved, _) = BookmarkStore(url: url).load()
        #expect(saved.contains { $0.id == id && $0.group == "Digital" })
    }

    @Test func starredBookmarkReturnsItsId() {
        let m = makeModel()
        let id = m.addBookmark()
        #expect(m.bookmarks.last?.id == id)
        #expect(m.bookmarks.last?.group == "Saved")
    }

    @Test func movingAndDeletingSeveral() {
        let m = makeModel()
        let a = m.addBookmark(Bookmark(name: "a", frequencyHz: 6_925_000, mode: .usb, bandwidthHz: 2_700))
        let b = m.addBookmark(Bookmark(name: "b", frequencyHz: 6_930_000, mode: .usb, bandwidthHz: 2_700, group: "Saved"))
        m.moveBookmarks([a, b], toGroup: "Pirates")
        #expect(m.bookmarks.filter { $0.group == "Pirates" }.count == 2)
        #expect(m.bookmarkGroups.contains("Pirates"))
        m.moveBookmarks([a], toGroup: "  ")
        #expect(m.bookmarks.first { $0.id == a }?.group == nil)
        let before = m.bookmarks.count
        m.deleteBookmarks([a, b])
        #expect(m.bookmarks.count == before - 2)
    }

    @Test func managerFiltersByGroupAgentAndUngrouped() {
        let agent = Bookmark(name: "a", frequencyHz: 1, mode: .usb, bandwidthHz: 1, group: "Pirates", addedBy: "Claude Code")
        let loose = Bookmark(name: "b", frequencyHz: 1, mode: .usb, bandwidthHz: 1)
        #expect(BookmarkFilter.fromAgents.includes(agent) && !BookmarkFilter.fromAgents.includes(loose))
        #expect(BookmarkFilter.ungrouped.includes(loose) && !BookmarkFilter.ungrouped.includes(agent))
        #expect(BookmarkFilter.group("pirates").includes(agent))
        #expect(BookmarkFilter.all.includes(agent) && BookmarkFilter.all.includes(loose))
    }
}
