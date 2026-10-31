import Foundation
import Modems
import SubFloorCore
import Testing
@testable import SubFloor

@MainActor
struct AppModelDecodeHistoryTests {
    @Test func slotDecodesReachTheHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                             defaults: UserDefaults(suiteName: UUID().uuidString)!,
                             openRSP: { throw CancellationError() }, rspOpenTimeout: .seconds(10),
                             decodeHistoryFolder: dir.appendingPathComponent("decodes"))
        let slot = Date()
        model.recordSlotDecodes([SlotDecode(mode: .ft8, slotStart: slot, frequencyHz: 1_234, snrDb: -7,
                                            timeOffset: 0.1, message: "CQ K1ABC FN42")])
        model.decodeHistory.flush()
        let heard = try #require(model.decodeHistory.decodes(since: slot.addingTimeInterval(-1)).first)
        #expect(heard.rfHz == model.modemBox.rfHz(forAudio: 1_234))
        #expect(heard.audioHz == 1_234)
        #expect(heard.from == "K1ABC")
        #expect(heard.grid == "FN42")
        #expect(heard.mode == "ft8")
        #expect(heard.snrDb == -7)
    }
}
