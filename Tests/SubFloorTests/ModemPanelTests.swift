import Foundation
import Modems
import SubFloorCore
import Testing
@testable import SubFloor

/// The modem panel's view-model: text formatting, status messages, slot progress and the bench's
/// geometry (`ModemPanelFormat`, `ModemPanelStatus`, `CursorBenchFeed`, `BenchGeometry`). The
/// SwiftUI views only lay these out.
@Suite struct ModemPanelTests {
    /// 2026-10-20 14:32:15 UTC.
    private let t143215 = Date(timeIntervalSince1970: 1_792_506_735)

    private func slotRow(mode: ModeID = .ft8, at time: Date, snr: Float, hz: Double, message: String) -> DecodeRow {
        DecodeRow(id: Int.min, frequencyHz: hz, mode: mode, submode: "", snrDb: snr, recentText: message,
                  history: message, isQuiet: false, isCursor: false, utcTime: time)
    }

    private func status(mode: ModeID? = .psk31, autoDetect: Bool = false, file: Bool = false, boxActive: Bool = true,
                        clockOffset: Double? = nil) -> ModemPanelStatus {
        ModemPanelStatus(mode: mode, autoDetect: autoDetect, isFileSource: file, boxActive: boxActive,
                         clockOffset: clockOffset, signalCount: 3, heldNewCount: 0, box: ModemBox(dialHz: 14_074_000))
    }

    // MARK: Formatting

    @Test func frequencyFormatting() {
        #expect(ModemPanelFormat.frequency(1_520) == "1,520 Hz")
        #expect(ModemPanelFormat.frequency(720) == "720 Hz")
        #expect(ModemPanelFormat.frequency(1_519.6) == "1,520 Hz")
        #expect(ModemPanelFormat.preciseFrequency(1_520.34) == "1,520.3 Hz")
        #expect(ModemPanelFormat.preciseFrequency(719.96) == "720.0 Hz")
        #expect(ModemPanelFormat.preciseFrequency(.nan) == "0.0 Hz")
        #expect(ModemPanelFormat.dial(ModemBox(dialHz: 14_074_000)) == "14.074.000 USB")
    }

    @Test func slotRowFormatting() {
        #expect(ModemPanelFormat.utcHHMMSS(t143215) == "143215")
        let row = slotRow(at: t143215, snr: -12.4, hz: 1_520, message: "CQ K1ABC FN42")
        #expect(ModemPanelFormat.slotRow(row) == "143215  -12  1,520 Hz  CQ K1ABC FN42")
        // Columns stay aligned for short fields; the time is UTC whatever the local zone.
        let short = slotRow(mode: .wspr, at: t143215.addingTimeInterval(-15), snr: 3, hz: 720, message: "K1ABC FN42 37")
        #expect(ModemPanelFormat.slotRow(short) == "143200   +3    720 Hz  K1ABC FN42 37")
        let midnight = slotRow(at: Date(timeIntervalSince1970: 1_792_454_400), snr: 0, hz: 2_000, message: "X")
        #expect(ModemPanelFormat.slotRow(midnight) == "000000   +0  2,000 Hz  X")
        #expect(ModemPanelFormat.utcHHMMSS(Date(timeIntervalSince1970: -1)) == "235959")
    }

    @Test func rowTextFormatting() {
        #expect(ModemPanelFormat.snr(12.4) == "+12 dB")
        #expect(ModemPanelFormat.snr(-3.6) == "-4 dB")
        #expect(ModemPanelFormat.snr(.nan) == "— dB")
        #expect(ModemPanelFormat.singleLine("CQ CQ\nDE K1ABC\r\n") == "CQ CQ DE K1ABC ")
        var row = slotRow(at: t143215, snr: 0, hz: 1_000, message: "")
        row.submode = "QPSK31"
        row.mode = .psk31
        #expect(ModemPanelFormat.modeLabel(row) == "QPSK31")
        row.submode = ""
        #expect(ModemPanelFormat.modeLabel(row) == "PSK31")
        row.mode = nil
        #expect(ModemPanelFormat.modeLabel(row) == "?")
        #expect(ModemPanelFormat.modeChoices.map(ModemPanelFormat.label(of:)) == ["Off", "CW", "PSK31", "RTTY", "FT8", "WSPR"])
        #expect(ModemPanelFormat.signalCount(1) == "1 signal")
        #expect(ModemPanelFormat.signalCount(0) == "0 signals")
        #expect(ModemPanelFormat.newRowsPill(0) == nil)
        #expect(ModemPanelFormat.newRowsPill(4) == "4 new ↓")
    }

    // MARK: Slot progress

    @Test func slotProgressFromDate() {
        let ft8 = ModemPanelFormat.slotProgress(.ft8, at: t143215.addingTimeInterval(3.25))
        #expect(ft8?.length == 15)
        #expect(abs((ft8?.fraction ?? -1) - 3.25 / 15) < 1e-9)
        #expect(ft8?.secondsRemaining == 12)
        #expect(ft8?.text == "FT8 12 s")
        // WSPR: 2-minute slots on even minutes (14:32:00), so 14:32:15 is 15 s in.
        let wspr = ModemPanelFormat.slotProgress(.wspr, at: t143215)
        #expect(wspr?.length == 120)
        #expect(abs((wspr?.fraction ?? -1) - 15.0 / 120) < 1e-9)
        #expect(wspr?.secondsRemaining == 105)
        // An odd minute is the second half of a WSPR slot.
        let odd = ModemPanelFormat.slotProgress(.wspr, at: t143215.addingTimeInterval(60))
        #expect(odd?.secondsRemaining == 45)
        // On a boundary a new slot starts with its whole length to go.
        let start = ModemPanelFormat.slotProgress(.ft8, at: t143215)
        #expect(start?.fraction == 0)
        #expect(start?.secondsRemaining == 15)
        #expect(ModemPanelFormat.slotProgress(.psk31, at: t143215) == nil)
    }

    // MARK: Status

    @Test func slotModesShownWhenActive() {
        #expect(status(mode: .ft8).slotModes == [.ft8])
        #expect(status(mode: .wspr).slotModes == [.wspr])
        #expect(status(mode: .psk31).slotModes.isEmpty)
        #expect(status(mode: .psk31, autoDetect: true).slotModes == [.ft8, .wspr])
        #expect(status(mode: nil, autoDetect: true).slotModes.isEmpty)
        #expect(status(mode: .ft8, file: true).slotModes.isEmpty)
        #expect(status(mode: .ft8, boxActive: false).slotModes.isEmpty)
    }

    @Test func messagesForFileSourceBoxAndClock() {
        #expect(status().messages.isEmpty)
        #expect(status(mode: nil, file: true, boxActive: false, clockOffset: 5).messages.isEmpty)

        #expect(status(mode: .ft8, file: true).messages == [.needsLiveRadio])
        #expect(status(mode: .rtty, autoDetect: true, file: true).messages == [.needsLiveRadio])
        #expect(status(mode: .rtty, file: true).messages.isEmpty)
        #expect(ModemPanelMessage.needsLiveRadio.text == "FT8/WSPR need a live radio")

        let outside = status(boxActive: false).messages
        #expect(outside == [.boxOutsideSpan])
        #expect(ModemPanelMessage.boxOutsideSpan.text == "Modem box is outside the captured band")
        #expect(ModemPanelMessage.boxOutsideSpan.offersRecenter)
        #expect(!ModemPanelMessage.needsLiveRadio.offersRecenter)

        // The clock matters only to running slot modes, and only beyond ±1 s.
        #expect(status(mode: .ft8, clockOffset: 1.0).messages.isEmpty)
        #expect(status(mode: .ft8, clockOffset: -0.4).messages.isEmpty)
        #expect(status(mode: .ft8, clockOffset: nil).messages.isEmpty)
        #expect(status(mode: .psk31, clockOffset: 3).messages.isEmpty)
        #expect(status(mode: .ft8, clockOffset: 1.42).messages == [.clock(offset: 1.42)])
        #expect(status(mode: .cw, autoDetect: true, clockOffset: -2).messages == [.clock(offset: -2)])
        #expect(ModemPanelMessage.clock(offset: 1.42).text == "System clock is 1.4 s slow — FT8/WSPR need it within 1 s of UTC")
        #expect(ModemPanelMessage.clock(offset: -2).text == "System clock is 2.0 s fast — FT8/WSPR need it within 1 s of UTC")

        // Several at once, most fundamental first.
        #expect(status(mode: .ft8, file: true, boxActive: false).messages == [.needsLiveRadio, .boxOutsideSpan])
    }

    @Test func statusTexts() {
        let s = status()
        #expect(s.signalCountText == "3 signals")
        #expect(s.dialText == "14.074.000 USB")
        #expect(s.newRowsPillText == nil)
        var held = s
        held.heldNewCount = 2
        #expect(held.newRowsPillText == "2 new ↓")
        #expect(s.isOn)
        #expect(!status(mode: nil).isOn)
    }

    // MARK: Bench

    @Test func benchReadouts() {
        let frame = CursorFrame(waveform: [], spectrumDb: [], spectrumCenterHz: 1_520, iq: [], frequencyHz: 1_520.34,
                                snrDb: 12.4, submode: "BPSK31", symbolRate: 31.25)
        let r = BenchReadouts(frame)
        #expect(r.waveform == "1,520.3 Hz")
        #expect(r.spectrum == "SNR +12 dB")
        #expect(r.iq == "BPSK31 · 31.25 Bd")
        let cw = CursorFrame(waveform: [], spectrumDb: [], spectrumCenterHz: 700, iq: [], frequencyHz: 700,
                             snrDb: -3, submode: "", symbolRate: nil)
        #expect(BenchReadouts(cw).iq == "—")
        let wspr = CursorFrame(waveform: [], spectrumDb: [], spectrumCenterHz: 1_500, iq: [], frequencyHz: 1_500,
                               snrDb: -20, submode: "WSPR", symbolRate: 12_000.0 / 8_192)
        #expect(BenchReadouts(wspr).iq == "WSPR · 1.465 Bd")
        #expect(ModemPanelFormat.benchPlaceholder == "Click a signal inside the box to analyse it")
    }

    @Test func benchFeedFollowsTheStoreAndTheLock() {
        let store = CursorFrameStore()
        let feed = CursorBenchFeed()
        func frame(_ hz: Double) -> CursorFrame {
            CursorFrame(waveform: [], spectrumDb: [], spectrumCenterHz: hz, iq: [], frequencyHz: hz, snrDb: 0,
                        submode: "", symbolRate: nil)
        }
        #expect(feed.update(from: store, cursorLocked: true) == nil)
        store.publish(frame(1_000), epoch: 0)
        #expect(feed.update(from: store, cursorLocked: true)?.frequencyHz == 1_000)
        // No newer frame: the last one stays up.
        #expect(feed.update(from: store, cursorLocked: true)?.frequencyHz == 1_000)
        // Unlocked: nothing shown, and the old frame does not return on the next lock.
        #expect(feed.update(from: store, cursorLocked: false) == nil)
        #expect(feed.update(from: store, cursorLocked: true) == nil)
        store.publish(frame(2_000), epoch: 0)
        #expect(feed.update(from: store, cursorLocked: true)?.frequencyHz == 2_000)
        // A box reset discards the store's frame: the bench clears too.
        store.discard(before: 1)
        #expect(feed.update(from: store, cursorLocked: true) == nil)
        store.publish(frame(3_000), epoch: 0)
        #expect(feed.update(from: store, cursorLocked: true) == nil)
        store.publish(frame(3_000), epoch: 1)
        #expect(feed.update(from: store, cursorLocked: true)?.frequencyHz == 3_000)
    }

    @Test func benchGeometry() {
        // Waveform: x across, peak-normalised, y down from the middle.
        let w = BenchGeometry.waveform([0, 0.5, 0, -0.5, 0])
        #expect(w.count == 5)
        #expect(w.first == SIMD2(0, 0.5))
        #expect(w.last == SIMD2(1, 0.5))
        #expect(abs(w[1].y - (0.5 - BenchGeometry.waveformAmplitude)) < 1e-9)
        #expect(abs(w[3].y - (0.5 + BenchGeometry.waveformAmplitude)) < 1e-9)
        #expect(BenchGeometry.waveform([0.3]).isEmpty)
        #expect(BenchGeometry.waveform([0, 0, 0]).allSatisfy { $0.y == 0.5 })

        // Spectrum: the strongest bin at the top, `spectrumRangeDb` below it at the bottom.
        let s = BenchGeometry.spectrum([-80, -20, -200])
        #expect(s.map(\.x) == [0, 0.5, 1])
        #expect(abs(s[1].y - BenchGeometry.spectrumTopMargin) < 1e-9)
        #expect(abs(s[0].y - (BenchGeometry.spectrumTopMargin + (1 - BenchGeometry.spectrumTopMargin))) < 1e-9)
        #expect(s[2].y == 1)
        #expect(BenchGeometry.spectrum([]).isEmpty)
        #expect(BenchGeometry.spectrum([.nan, -10]).allSatisfy { $0.y.isFinite })

        // IQ: centred, the largest component at ±0.45, oldest faintest.
        let iq = BenchGeometry.iq([SIMD2(1, 0), SIMD2(0, -2), SIMD2(0, 0)])
        #expect(iq.count == 3)
        #expect(abs(iq[0].point.x - 0.725) < 1e-6 && abs(iq[0].point.y - 0.5) < 1e-6)
        #expect(abs(iq[1].point.y - 0.95) < 1e-6)
        #expect(iq[2].point == SIMD2(0.5, 0.5))
        #expect(iq[0].opacity < iq[1].opacity && iq[1].opacity < iq[2].opacity && iq[2].opacity == 1)
        #expect(BenchGeometry.iq([]).isEmpty)
    }
}
