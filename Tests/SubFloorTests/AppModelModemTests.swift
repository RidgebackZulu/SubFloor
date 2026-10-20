import Foundation
import Modems
import SubFloorCore
import Testing
@testable import SubFloor

/// The modem box, cursor and settings on a hermetic model (never started). The rules themselves
/// are `ModemControlTests`'; these check AppModel's wiring.
@MainActor
struct AppModelModemTests {
    private func makeModel(defaults: UserDefaults? = nil) -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                        defaults: defaults ?? UserDefaults(suiteName: UUID().uuidString)!)
    }

    @Test func recenterPlacesBoxAtViewCenter() {
        let m = makeModel()
        m.zoom(by: 0.1, anchor: 0.3)
        m.recenterModemBox()
        #expect(abs(m.modemBox.centerHz - m.viewport.centerHz) < 1e-6)
        #expect(m.modemBoxActive)
    }

    @Test func boxStaysPutOnVFOClick() {
        let m = makeModel()
        m.setModemMode(.psk31)
        let box = m.modemBox
        let vfo = m.vfoHz
        let f = 0.9
        #expect(!box.contains(rf: m.viewport.hz(atFraction: f)))
        m.click(atFraction: f)
        #expect(m.vfoHz != vfo)
        #expect(m.modemBox == box)
    }

    @Test func lockCursorConvertsToAudio() {
        let m = makeModel()
        var updates: [ModemEngineUpdate] = []
        m.onModemEngineUpdate = { updates.append($0) }
        m.setModemMode(.psk31)
        m.lockModemCursor(atRF: m.modemBox.dialHz + 1_520)
        #expect(m.modemCursorAudioHz == 1_520)
        #expect(updates.last == .command(.lock(audioHz: 1_520)))
        m.unlockModemCursor()
        #expect(m.modemCursorAudioHz == nil)
        #expect(updates.last == .command(.unlock))
    }

    @Test func boxOutsideSpanInactive() {
        let m = makeModel()
        var updates: [ModemEngineUpdate] = []
        m.onModemEngineUpdate = { updates.append($0) }
        m.setModemMode(.psk31)
        #expect(m.modemBoxActive)
        let center = m.centerHz
        m.setVFO(m.vfoHz + 1_000_000)
        #expect(m.centerHz != center)
        #expect(!m.modemBoxActive)
        #expect(updates.last == .boxDialOffset(nil))
        #expect(m.modemBoxFractions == nil)
        m.recenterModemBox()
        #expect(m.modemBoxActive)
        #expect(updates.last == .boxDialOffset(m.modemBox.dialHz - m.centerHz))
    }

    @Test func slotModesDisabledForFileSource() {
        let m = makeModel()
        var updates: [ModemEngineUpdate] = []
        m.onModemEngineUpdate = { updates.append($0) }
        m.setModemMode(.ft8)
        #expect(m.modemSettings.slotModesEnabled)
        m.setSourceKindForTesting(.file)
        #expect(m.sourceKind == .file)
        #expect(m.modemSettings.slotModesEnabled == false)
        #expect(updates.last == .settings(ModemSettings(mode: .ft8, slotModesEnabled: false)))
    }

    @Test func modeOffRestoresVFOAudio() {
        let m = makeModel()
        var updates: [ModemEngineUpdate] = []
        m.onModemEngineUpdate = { updates.append($0) }
        m.setModemMode(.rtty)
        m.lockModemCursor(atRF: m.modemBox.dialHz + 1_000)
        m.setModemMode(nil)
        #expect(m.modemSettings.mode == nil)
        #expect(m.modemCursorAudioHz == nil)
        #expect(updates.last == .settings(ModemSettings(mode: nil)))
    }

    @Test func boxDragMovesTheBoxNotTheVFO() {
        let m = makeModel()
        m.setModemMode(.psk31)
        let dial = m.modemBox.dialHz
        let vfo = m.vfoHz
        m.dragModemBox(byFraction: 0.001)
        #expect(abs(m.modemBox.dialHz - (dial + 0.001 * m.viewport.spanHz)) < 1e-6)
        #expect(m.vfoHz == vfo)
    }

    @Test func sessionPersistsBoxAndSettings() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let m = makeModel(defaults: defaults)
        m.setModemMode(.psk31)
        m.setAutoDetect(true)
        m.setAudioWide(true)
        m.moveModemBox(byHz: 2_345)
        let box = m.modemBox
        m.shutdown()

        let restored = makeModel(defaults: defaults)
        #expect(restored.modemBox == box)
        #expect(restored.modemSettings == ModemSettings(mode: .psk31, autoDetect: true, audioWide: true))
    }
}
