import Foundation
import Modems
import SubFloorCore
import Testing
@testable import SubFloor

@Suite struct ModemControlTests {
    private let centre = 14_100_000.0
    private let span = 2_000_000.0

    private func control(mode: ModeID? = .psk31) -> ModemControl {
        var c = ModemControl(box: ModemBox(dialHz: 14_074_000), settings: ModemSettings(mode: mode))
        _ = c.takeEngineUpdates(captureCenter: centre, captureSpan: span, isFileSource: false)
        return c
    }

    private func take(_ c: inout ModemControl, centre: Double? = nil, file: Bool = false) -> [ModemEngineUpdate] {
        c.takeEngineUpdates(captureCenter: centre ?? self.centre, captureSpan: span, isFileSource: file)
    }

    private func snapshot(_ id: Int, _ hz: Double, cursor: Bool) -> SignalSnapshot {
        SignalSnapshot(id: id, frequencyHz: hz, snrDb: 10, mode: .psk31, submode: "", isQuiet: false, isCursor: cursor)
    }

    // MARK: Engine updates

    @Test func sendsOnlyWhatChanged() {
        var c = ModemControl(box: ModemBox(dialHz: 14_074_000))
        #expect(take(&c) == [.settings(ModemSettings()), .boxDialOffset(14_074_000 - centre)])
        #expect(take(&c).isEmpty)
        c.setMode(.rtty)
        #expect(take(&c) == [.settings(ModemSettings(mode: .rtty))])
        c.setAutoDetect(true)
        c.setAudioWide(true)
        #expect(take(&c) == [.settings(ModemSettings(mode: .rtty, autoDetect: true, audioWide: true))])
        c.moveBox(byHz: 100, captureCenter: centre, captureSpan: span)
        #expect(take(&c) == [.boxDialOffset(14_074_100 - centre)])
    }

    @Test func boxOutsideTheSpanSendsNilAndResumes() {
        var c = control()
        #expect(c.isBoxActive(captureCenter: centre, captureSpan: span))
        // A retune 1 MHz up: the box is outside.
        let far = centre + 1_000_000
        #expect(!c.isBoxActive(captureCenter: far, captureSpan: span))
        #expect(take(&c, centre: far) == [.boxDialOffset(nil)])
        #expect(take(&c, centre: far).isEmpty)
        // Back: the offset again (the engine resets on it).
        #expect(take(&c) == [.boxDialOffset(14_074_000 - centre)])
        // Re-centring while far brings it inside the new span.
        c.recenter(on: far, captureCenter: far, captureSpan: span)
        #expect(c.box.centerHz == far)
        #expect(take(&c, centre: far) == [.boxDialOffset(c.box.dialHz - far)])
    }

    @Test func slotModesFollowTheSource() {
        var c = control()
        #expect(c.engineSettings(isFileSource: true).slotModesEnabled == false)
        #expect(c.engineSettings(isFileSource: false).slotModesEnabled)
        #expect(take(&c, file: true) == [.settings(ModemSettings(mode: .psk31, slotModesEnabled: false))])
        #expect(c.settings.slotModesEnabled)   // the user's settings are unchanged
    }

    @Test func modeOffSendsNilModeAndDropsTheCursor() {
        var c = control()
        c.lock(atRF: 14_075_520, boxActive: true)
        _ = take(&c)
        c.setMode(nil)
        #expect(c.cursorAudioHz == nil)
        #expect(take(&c) == [.settings(ModemSettings())])
    }

    // MARK: Cursor

    @Test func lockConvertsToAudioAfterTheSettings() {
        var c = ModemControl(box: ModemBox(dialHz: 14_074_000))
        _ = take(&c)
        c.setMode(.psk31)
        c.lock(atRF: 14_074_000 + 1_520, boxActive: true)
        #expect(c.cursorAudioHz == 1_520)
        #expect(take(&c) == [.settings(ModemSettings(mode: .psk31)), .command(.lock(audioHz: 1_520))])
    }

    @Test func lockNeedsTheModemOnTheBoxActiveAndAPointInside() {
        var off = control(mode: nil)
        off.lock(atRF: 14_075_520, boxActive: true)
        #expect(off.cursorAudioHz == nil)
        var c = control()
        c.lock(atRF: 14_075_520, boxActive: false)
        c.lock(atRF: 14_074_100, boxActive: true)   // audio 100 Hz: below the box
        c.lock(atRF: .nan, boxActive: true)
        c.nudge(1, boxActive: false)
        #expect(c.cursorAudioHz == nil)
        #expect(take(&c).isEmpty)
    }

    @Test func clickOnTheCursorUnlocksElsewhereRelocks() {
        var c = control()
        c.click(atRF: 14_075_520, spanHz: 1_000, boxActive: true)
        #expect(c.cursorAudioHz == 1_520)
        // 1 kHz view: within 4 Hz of the cursor unlocks.
        c.click(atRF: 14_075_523, spanHz: 1_000, boxActive: true)
        #expect(c.cursorAudioHz == nil)
        c.click(atRF: 14_075_520, spanHz: 1_000, boxActive: true)
        c.click(atRF: 14_075_530, spanHz: 1_000, boxActive: true)
        #expect(c.cursorAudioHz == 1_530)
        // Zoomed out the tolerance is capped at 10 Hz.
        c.click(atRF: 14_075_545, spanHz: 2_000_000, boxActive: true)
        #expect(c.cursorAudioHz == 1_545)
        #expect(take(&c) == [.command(.lock(audioHz: 1_520)), .command(.unlock), .command(.lock(audioHz: 1_520)),
                             .command(.lock(audioHz: 1_530)), .command(.lock(audioHz: 1_545))])
        c.unlock()
        c.unlock()   // already unlocked: nothing to send
        #expect(take(&c) == [.command(.unlock)])
    }

    @Test func snapshotsFollowTheCursorButNotStaleOnes() {
        var c = control()
        c.lock(atRF: 14_075_520, boxActive: true)
        // A snapshot from before the lock: the old cursor elsewhere.
        c.apply(signals: [snapshot(1, 800, cursor: true), snapshot(2, 1_510, cursor: false)])
        #expect(c.cursorAudioHz == 1_520)
        // The engine snapped to the track at 1512.
        c.apply(signals: [snapshot(2, 1_512, cursor: true)])
        #expect(c.cursorAudioHz == 1_512)
        // Then AFC follows the drift, however far.
        c.apply(signals: [snapshot(2, 1_560, cursor: true)])
        #expect(c.cursorAudioHz == 1_560)
        c.apply(signals: nil)
        c.apply(signals: [snapshot(2, 1_560, cursor: false)])
        #expect(c.cursorAudioHz == 1_560)
        // Unlocked: snapshots still listing the cursor are ignored.
        c.unlock()
        c.apply(signals: [snapshot(2, 1_560, cursor: true)])
        #expect(c.cursorAudioHz == nil)
    }

    @Test func nudgeTakesTheNextSnapshotCursor() {
        var c = control()
        c.nudge(1, boxActive: true)
        #expect(c.cursorAudioHz == nil)
        #expect(take(&c) == [.command(.nudge(1))])
        c.apply(signals: [snapshot(5, 2_200, cursor: true)])
        #expect(c.cursorAudioHz == 2_200)
    }

    @Test func boxLeavingTheSpanDropsTheCursor() {
        var c = control()
        c.lock(atRF: 14_075_520, boxActive: true)
        _ = take(&c)
        _ = take(&c, centre: centre + 1_000_000)
        #expect(c.cursorAudioHz == nil)
    }

    @Test func selectingRows() {
        var c = control()
        let live = DecodeRow(id: 3, frequencyHz: 1_000, mode: .psk31, submode: "", snrDb: 5, recentText: "", history: "",
                             isQuiet: false, isCursor: false, utcTime: nil)
        c.select(live, boxActive: true)
        #expect(c.cursorAudioHz == 1_000)
        var cursorRow = live
        cursorRow.isCursor = true
        c.select(cursorRow, boxActive: true)
        #expect(c.cursorAudioHz == nil)
        // An FT8 slot row reports tone 0: the cursor goes to the signal's centre.
        let slot = DecodeRow(id: Int.min, frequencyHz: 1_200, mode: .ft8, submode: "", snrDb: -10, recentText: "CQ",
                             history: "CQ", isQuiet: false, isCursor: false, utcTime: Date(timeIntervalSince1970: 0))
        c.select(slot, boxActive: true)
        #expect(c.cursorAudioHz == 1_200 + 3.5 * FT8Encoder.toneSpacing)
    }

    @Test func grabTabLabel() {
        var c = control()
        #expect(c.grabTabLabel == "≡ PSK31 · 3 kHz")
        c.setAutoDetect(true)
        #expect(c.grabTabLabel == "AUTO · 3 kHz")
    }

    // MARK: With the engine (never started)

    @Test func engineResetDropsTheCursorButNotALockAfterIt() {
        let engine = DSPEngine()
        var c = ModemControl(box: ModemBox(dialHz: 14_074_000))
        c.sync(engine, captureCenter: centre, captureSpan: span, isFileSource: false)
        c.setMode(.psk31)
        c.sync(engine, captureCenter: centre, captureSpan: span, isFileSource: false)
        c.lock(atRF: 14_075_520, boxActive: true)
        c.sync(engine, captureCenter: centre, captureSpan: span, isFileSource: false)
        #expect(c.cursorAudioHz == 1_520)
        let epoch = engine.modemEvents.epoch

        // A small drag: no reset, the cursor stays.
        c.moveBox(byHz: 3, captureCenter: centre, captureSpan: span)
        c.sync(engine, captureCenter: centre, captureSpan: span, isFileSource: false)
        #expect(engine.modemEvents.epoch == epoch)
        #expect(c.cursorAudioHz == 1_520)

        // A larger one resets the box, which unlocks the cursor.
        c.moveBox(byHz: 10, captureCenter: centre, captureSpan: span)
        c.sync(engine, captureCenter: centre, captureSpan: span, isFileSource: false)
        #expect(engine.modemEvents.epoch > epoch)
        #expect(c.cursorAudioHz == nil)

        // A re-centre and a lock in one go: the lock follows the reset and stays.
        c.recenter(on: 14_200_000, captureCenter: centre, captureSpan: span)
        c.lock(atRF: c.box.rfHz(forAudio: 1_000), boxActive: true)
        let updates = c.sync(engine, captureCenter: centre, captureSpan: span, isFileSource: false)
        #expect(updates == [.boxDialOffset(c.box.dialHz - centre), .command(.lock(audioHz: 1_000))])
        #expect(c.cursorAudioHz == 1_000)
        c.observeEpoch(engine.modemEvents.epoch)
        #expect(c.cursorAudioHz == 1_000)
    }

    @Test func drainedBatchesFillAndClearTheLog() {
        let events = ModemEventQueue()
        var c = control()
        var log = DecodeLog()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = events.beginEpoch(at: now)
        c.lock(atRF: 14_075_520, boxActive: true)
        _ = take(&c)
        c.commandsSent(inEpoch: first)
        events.append(text: [DecodedText(trackID: 1, text: "CQ CQ")], signals: [snapshot(1, 1_515, cursor: true)], epoch: first)
        c.take(events.drain(), into: &log, now: now)
        #expect(log.liveRows.map(\.recentText) == ["CQ CQ"])
        #expect(c.cursorAudioHz == 1_515)

        // Nothing new: nothing changes.
        c.take(events.drain(), into: &log, now: now)
        #expect(log.liveRows.count == 1)

        // A reset (the box moved): the batch clears the log, and the cursor (locked before it) goes.
        let second = events.beginEpoch(at: now.addingTimeInterval(1))
        #expect(!events.append(text: [DecodedText(trackID: 1, text: "old")], signals: nil, epoch: first))
        events.append(text: [], signals: [snapshot(7, 900, cursor: false)], epoch: second)
        c.take(events.drain(), into: &log, now: now.addingTimeInterval(1))
        #expect(log.liveRows.map(\.id) == [7])
        #expect(log.liveRows.allSatisfy { $0.recentText.isEmpty })
        #expect(c.cursorAudioHz == nil)
    }
}
