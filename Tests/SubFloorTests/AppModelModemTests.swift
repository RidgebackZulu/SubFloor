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

    /// The receiver's default: USB, 2.7 kHz. Its decode band: 300…2800 Hz above the VFO.
    private let usbBand = 300.0...2_800.0

    @Test func boxFollowsThePassband() {
        let m = makeModel()
        m.setModemMode(.ft8)
        #expect(m.modemBox.dialHz == m.vfoHz, "USB: the dial is the VFO")
        #expect(m.modemAudioBand == usbBand)
        #expect(m.modemBoxActive)
        m.setVFO(14_074_000)
        #expect(m.modemBox.dialHz == 14_074_000)
        m.setBandwidth(1_500)
        #expect(m.modemAudioBand == 300...1_600)
        // The decode band in view fractions is the passband's part of the box.
        let f = m.modemBoxFractions
        #expect(f.map { abs(m.viewport.hz(atFraction: $0.lower) - 14_074_300) < 1 } == true)
        #expect(f.map { abs(m.viewport.hz(atFraction: $0.upper) - 14_075_600) < 1 } == true)
    }

    @Test func clickOutsideThePassbandTunesAndTheBoxFollows() {
        let m = makeModel()
        m.setModemMode(.psk31)
        let vfo = m.vfoHz
        let f = 0.9
        #expect(!m.modemBox.contains(rf: m.viewport.hz(atFraction: f)))
        m.click(atFraction: f)
        #expect(m.vfoHz != vfo)
        #expect(m.modemBox.dialHz == m.vfoHz)
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
        // Outside the decode band (above the 2.8 kHz passband): no lock.
        m.lockModemCursor(atRF: m.modemBox.dialHz + 3_000)
        #expect(m.modemCursorAudioHz == nil)
    }

    @Test func retuningFarAwayKeepsTheBoxOnTheVFO() {
        let m = makeModel()
        var updates: [ModemEngineUpdate] = []
        m.onModemEngineUpdate = { updates.append($0) }
        m.setModemMode(.psk31)
        let center = m.centerHz
        m.setVFO(m.vfoHz + 1_000_000)
        #expect(m.centerHz != center)
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
        #expect(updates.last == .settings(ModemSettings(mode: .ft8, slotModesEnabled: false, audioBand: usbBand)))
    }

    @Test func modeOffSendsNilMode() {
        let m = makeModel()
        var updates: [ModemEngineUpdate] = []
        m.onModemEngineUpdate = { updates.append($0) }
        m.setModemMode(.psk31)
        m.lockModemCursor(atRF: m.modemBox.dialHz + 1_000)
        m.setModemMode(nil)
        #expect(m.modemSettings.mode == nil)
        #expect(m.modemCursorAudioHz == nil)
        #expect(updates.last == .settings(ModemSettings(mode: nil, audioBand: usbBand)))
    }

    @Test func disabledModesAreNotOffered() {
        let m = makeModel()
        m.setModemMode(.rtty)
        #expect(m.modemSettings.mode == nil)
        #expect(!m.modemSettings.autoDetect)
    }

    @Test func sessionPersistsTheModeAndTheBoxFollowsTheVFO() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let m = makeModel(defaults: defaults)
        m.setModemMode(.psk31)
        m.setVFO(14_070_000)
        m.shutdown()

        let restored = makeModel(defaults: defaults)
        #expect(restored.modemSettings.mode == .psk31)
        #expect(restored.vfoHz == 14_070_000)
        #expect(restored.modemBox.dialHz == 14_070_000)
    }
}
