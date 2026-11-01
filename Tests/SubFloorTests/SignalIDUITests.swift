import AppKit
import DSPCore
import Foundation
import Modems
import Recording
import SDRplayKit
import SignalID
import SubFloorCore
import Synchronization
import SwiftUI
import Testing
@testable import SubFloor

/// A value shared with the closures the service runs off the main actor.
private final class Locked<Value: Sendable>: Sendable {
    private let value: Mutex<Value>
    init(_ value: Value) { self.value = Mutex(value) }
    func withLock<R>(_ body: (inout Value) -> R) -> R { value.withLock { body(&$0) } }
}

/// Task 8: the hover line and the right-click ID card. A demo-source model with a stub analysis where the test
/// is about the UI, not the identifier; the card and the line drawn offscreen.
@MainActor
struct SignalIDUITests {
    private static let view = CGSize(width: 1000, height: 500)

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A model that never opens the real RSP, not running anything.
    private func idleModel() -> AppModel {
        let dir = tempDir()
        return AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                        defaults: UserDefaults(suiteName: UUID().uuidString)!,
                        openRSP: { throw SDRplayError.noDevice }, decodeHistoryFolder: dir)
    }

    /// A model running the demo source, or nil where the engine can't start (no audio device: tolerated).
    private func runningModel() -> AppModel? {
        let m = idleModel()
        m.useSource(.synthetic)
        guard m.isRunning else {
            print("engine did not start (tolerated, no audio device)")
            m.shutdown()
            return nil
        }
        return m
    }

    private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline {
                await Task.yield()
                return condition()
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private static func snapshot(seconds: Double) -> IQSnapshot {
        IQSnapshot(samples: SignalSynth.make(.noise, sampleRate: 48_000, seconds: seconds, snrDb: 20, offsetHz: 0,
                                             seed: 3),
                   sampleRate: 48_000, endTime: Date())
    }

    private static func provider(_ snap: IQSnapshot) -> SignalIDService.SnapshotProvider {
        { lastSeconds in
            var newest = snap
            newest.samples = Array(snap.samples.suffix(2 * Int((lastSeconds * snap.sampleRate).rounded())))
            return newest
        }
    }

    private static func chunks(_ snap: IQSnapshot) -> SignalIDService.ChunkProvider {
        { lastSeconds, chunkFrames, visit in
            let frames = min(snap.frames, Int((lastSeconds * snap.sampleRate).rounded()))
            let iq = snap.samples.suffix(2 * frames)
            var start = iq.startIndex
            while start < iq.endIndex {
                let end = min(start + 2 * chunkFrames, iq.endIndex)
                guard iq[start..<end].withUnsafeBufferPointer(visit) else { return nil }
                start = end
            }
            return IQRead(frames: frames, sampleRate: snap.sampleRate, endTime: snap.endTime)
        }
    }

    /// A stub analysis: a 250 Hz RTTY centred where it was asked, counting its runs.
    /// With `holdLongerRead`, the longer read's analysis waits until that flag is cleared.
    private static func rtty(runs: Locked<Int>? = nil, needsLongerRead: Bool = false, firstAfter first: Double = 0,
                             holdLongerRead: Locked<Bool>? = nil) -> SignalIDService.Analysis {
        { _, _, centre, at, _, _, longer in
            runs?.withLock { $0 += 1 }
            if longer == nil, first > 0 { Thread.sleep(forTimeInterval: first) }
            if longer != nil, let hold = holdLongerRead {
                let deadline = Date().addingTimeInterval(20)
                while hold.withLock({ $0 }), Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            }
            return SignalIdentity(measurement: SignalMeasurement(offsetHz: at - centre, occupiedBandwidthHz: 250,
                                                                 snrDb: 22, envelope: .steady, family: .fsk,
                                                                 familyConfidence: 0.9, symbolRate: 45.45,
                                                                 fskShiftHz: 170, toneCount: 2, seconds: 3),
                                  best: ModeMatch(name: "RTTY", confidence: 0.91, evidence: ["45.45 Bd"]),
                                  needsLongerRead: needsLongerRead && longer == nil)
        }
    }

    // MARK: Identities for the card

    static let rtty = SignalIdentity(
        measurement: SignalMeasurement(offsetHz: 12_000, occupiedBandwidthHz: 250, bandwidth6dBHz: 180, snrDb: 22,
                                       envelope: .steady, family: .fsk, familyConfidence: 0.9, symbolRate: 45.45,
                                       fskShiftHz: 170, toneCount: 2, seconds: 3,
                                       notes: ["bandwidth from parameters"]),
        best: ModeMatch(name: "RTTY", confidence: 0.91,
                        evidence: ["2 tones, 170 Hz apart: 170 Hz shift", "45.45 Bd matches 45.45",
                                   "in the 20 m RTTY sub-band (+0.10)"]),
        alternatives: [ModeMatch(name: "NAVTEX / SITOR-B", confidence: 0.42, evidence: ["100 Bd is not 45.45"]),
                       ModeMatch(name: "MFSK16", confidence: 0.31, evidence: [])],
        confirmedByDecode: true)

    static let familyOnly = SignalIdentity(
        measurement: SignalMeasurement(offsetHz: -3_000, occupiedBandwidthHz: 840, bandwidth6dBHz: 700, snrDb: 14,
                                       envelope: .steady, family: .fsk, familyConfidence: 0.8, symbolRate: 50,
                                       fskShiftHz: 850, toneCount: 2, seconds: 3),
        alternatives: [ModeMatch(name: "RTTY", confidence: 0.55, evidence: [])],
        needsLongerRead: false, note: "Read 1.4 s of the 3 s asked for")

    static let tooWeak = SignalIdentity(
        measurement: SignalMeasurement(offsetHz: 5_000, snrDb: 2, seconds: 3), note: "Too weak to identify (SNR 2 dB)")

    static let noSignal = SignalIdentity(measurement: SignalMeasurement(offsetHz: 5_000, seconds: 3), note: "No signal")

    // MARK: Hover

    /// Half a second's dwell starts an identification; a move of 10 px inside 0.3 s cancels that dwell, and the
    /// rest after it starts exactly one.
    @Test func hoverWaitsForADwellAndCancels() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let runs = Locked(0)
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(seconds: 3.1))
        m.signalID.analysis = Self.rtty(runs: runs)

        m.hover(at: CGPoint(x: 0.500, y: 0.2), viewSize: Self.view)
        try await Task.sleep(for: .milliseconds(300))
        m.hover(at: CGPoint(x: 0.510, y: 0.2), viewSize: Self.view)   // 10 px, 0.3 s in
        try await Task.sleep(for: .milliseconds(300))                 // 0.6 s after the first: no dwell ran out
        #expect(runs.withLock { $0 } == 0)
        #expect(m.signalID.hoverIdentity == nil)
        try await Task.sleep(for: .milliseconds(450))                 // 0.75 s after the second
        #expect(await eventually { m.signalID.hoverIdentity != nil })
        #expect(runs.withLock { $0 } == 1)
    }

    /// After the first pass asks for a longer read, the first answer is on the line with `measuring` set until the
    /// longer read's answer replaces it.
    @Test func hoverShowsTheFirstAnswerWhileTheLongerReadRuns() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let snap = Self.snapshot(seconds: 3.1)
        m.signalID.snapshotProvider = Self.provider(snap)
        m.signalID.chunkProvider = Self.chunks(snap)
        let hold = Locked(true)
        m.signalID.analysis = Self.rtty(needsLongerRead: true, firstAfter: 0.4, holdLongerRead: hold)

        m.hover(at: CGPoint(x: 0.5, y: 0.2), viewSize: Self.view)
        #expect(await eventually { m.signalID.hoverPending })
        #expect(!m.signalID.hoverMeasuring)
        #expect(await eventually { m.signalID.hoverIdentity != nil })
        #expect(m.signalID.hoverMeasuring)
        #expect(!m.signalID.hoverPending)
        #expect(m.signalID.hoverIdentity?.needsLongerRead == true)
        hold.withLock { $0 = false }
        #expect(await eventually { !m.signalID.hoverMeasuring })
        #expect(m.signalID.hoverIdentity?.needsLongerRead == false)
        // Moving away clears the flag with the answer.
        m.hover(at: CGPoint(x: 0.8, y: 0.2), viewSize: Self.view)
        #expect(m.signalID.hoverIdentity == nil && !m.signalID.hoverMeasuring)
    }

    @Test func hoverLineTexts() {
        let named = SignalIDText.hoverLine(identity: Self.rtty, pending: false, measuring: false)
        #expect(named == "RTTY · 45.45 Bd · 170 Hz shift · 91%")
        #expect(SignalIDText.hoverLine(identity: nil, pending: true, measuring: false) == "Identifying…")
        #expect(SignalIDText.hoverLine(identity: nil, pending: false, measuring: false) == nil)
        #expect(SignalIDText.hoverLine(identity: Self.rtty, pending: false, measuring: true)
                == "RTTY · 45.45 Bd · 170 Hz shift · 91% · measuring…")
        #expect(SignalIDText.hoverLine(identity: Self.familyOnly, pending: false, measuring: false)
                == "2-FSK · 50 Bd · 850 Hz shift")
        #expect(SignalIDText.hoverLine(identity: Self.tooWeak, pending: false, measuring: false)
                == "Too weak to identify (SNR 2 dB)")
        #expect(SignalIDText.hoverLine(identity: Self.noSignal, pending: false, measuring: false) == "No signal")
        // A pending run with an answer already up is the longer read, not a first one.
        #expect(SignalIDText.hoverLine(identity: Self.rtty, pending: true, measuring: false)
                == "RTTY · 45.45 Bd · 170 Hz shift · 91%")
    }

    // MARK: Card actions

    @Test func tuneFromCardPicksTheDemod() {
        let m = idleModel()
        defer { m.shutdown() }
        m.setMode(.am)
        // RTTY on 20 m: USB, the passband placed over the signal (SSB passbands start 100 Hz above the carrier).
        let signal = 14_080_000.0
        m.tuneToIdentified(Self.rtty, atHz: signal)
        #expect(m.mode == .usb)
        #expect(m.bandwidthHz == 2_700)
        #expect(abs(m.vfoHz - (signal - DemodMode.usb.passbandOffset(bandwidth: 2_700))) < 1)
        #expect(m.displayedPassband.contains(signal))

        // A family-only 2-FSK at VHF: NFM, tuned to its centre.
        var vhf = Self.familyOnly
        vhf.measurement.family = .fm
        m.tuneToIdentified(vhf, atHz: 145_500_000)
        #expect(m.mode == .nfm && m.vfoHz == 145_500_000)

        // Too weak or no signal: the frequency only, the mode stays.
        m.setMode(.cw)
        m.tuneToIdentified(Self.tooWeak, atHz: 7_030_000)
        #expect(m.mode == .cw && m.vfoHz == 7_030_000)
    }

    @Test func demodByNameAndFamily() {
        func demod(_ name: String?, _ family: SignalFamily, at hz: Double, width: Double = 500) -> DemodMode? {
            var m = SignalMeasurement(occupiedBandwidthHz: width, snrDb: 20, family: family)
            m.family = family
            return SignalIDTuning.demod(for: SignalIdentity(
                measurement: m, best: name.map { ModeMatch(name: $0, confidence: 0.9, evidence: []) }), atHz: hz)
        }
        #expect(demod("CW", .ook, at: 7_030_000) == .cw)
        #expect(demod("AM voice/broadcast", .am, at: 6_000_000) == .am)
        #expect(demod("NFM voice", .fm, at: 146_000_000) == .nfm)
        #expect(demod("WFM broadcast", .wfm, at: 98_000_000) == .wfm)
        #expect(demod("DMR", .fsk, at: 440_000_000) == .nfm)
        #expect(demod("AIS", .fsk, at: 162_000_000) == .nfm)
        #expect(demod("FT8 / FT4", .fsk, at: 14_074_000) == .usb)
        #expect(demod("PSK31 / PSK63", .psk, at: 3_580_000) == .usb)
        // SSB voice by its measured sideband, else by the convention (LSB below 10 MHz).
        #expect(demod("SSB voice (USB/LSB)", .lsb, at: 14_200_000) == .lsb)
        #expect(demod("SSB voice (USB/LSB)", .usb, at: 7_100_000) == .usb)
        #expect(demod("SSB voice (USB/LSB)", .unknown, at: 7_100_000) == .lsb)
        #expect(demod("SSB voice (USB/LSB)", .unknown, at: 14_200_000) == .usb)
        // No name: the family's; digital families by the band (HF sideband, VHF FM).
        #expect(demod(nil, .usb, at: 14_200_000) == .usb)
        #expect(demod(nil, .lsb, at: 14_200_000) == .lsb)
        #expect(demod(nil, .am, at: 1_000_000) == .am)
        #expect(demod(nil, .fm, at: 146_000_000) == .nfm)
        #expect(demod(nil, .wfm, at: 98_000_000) == .wfm)
        #expect(demod(nil, .ook, at: 7_030_000) == .cw)
        #expect(demod(nil, .carrier, at: 10_000_000) == .cw)
        #expect(demod(nil, .fsk, at: 14_080_000) == .usb)
        #expect(demod(nil, .fsk, at: 150_000_000) == .nfm)
        #expect(demod(nil, .ofdm, at: 10_000_000) == .usb)
        #expect(SignalIDTuning.demod(for: Self.tooWeak, atHz: 7_000_000) == nil)
        #expect(SignalIDTuning.demod(for: Self.noSignal, atHz: 7_000_000) == nil)
    }

    /// Every row of the mode table has a demod, so a new row can't be added without one.
    @Test func everyTableRowHasADemod() {
        for row in ModeTable.rows {
            #expect(SignalIDTuning.demod(forTableRow: row.name, family: .unknown, atHz: 14_000_000) != nil, "\(row.name)")
        }
    }

    @Test func bookmarkFromCardFillsNotes() throws {
        let m = idleModel()
        defer { m.shutdown() }
        let signal = 14_080_000.0
        let now = Date(timeIntervalSince1970: 1_793_491_200)   // 2026-11-01
        let before = m.bookmarks.count
        let id = try #require(m.bookmarkIdentified(Self.rtty, atHz: signal, now: now))
        let b = try #require(m.bookmarks.first { $0.id == id })
        #expect(b.name == "RTTY")
        #expect(b.group == "Identified")
        #expect(b.mode == .usb && b.bandwidthHz == 2_700)
        #expect(abs(b.frequencyHz - (signal - DemodMode.usb.passbandOffset(bandwidth: 2_700))) < 1)
        #expect(b.upconverter == false)
        #expect(b.created != nil)
        let notes = try #require(b.notes)
        #expect(notes.contains("RTTY · 45.45 Bd · 170 Hz shift · 91%"))
        #expect(notes.contains("Symbol rate: 45.45 Bd"))
        #expect(notes.contains("Shift: 170 Hz"))
        #expect(notes.contains("Bandwidth: 250 Hz"))
        #expect(notes.contains("Signal at 14.080.000 Hz"))
        #expect(notes.contains("Identified 2026-11-01"))
        #expect(notes.contains("confirmed by decode"))

        // A family-only match is named by its family; a signal-less one can't be bookmarked.
        let fam = try #require(m.bookmarkIdentified(Self.familyOnly, atHz: 7_100_000))
        #expect(m.bookmarks.first { $0.id == fam }?.name == "2-FSK")
        #expect(m.bookmarkIdentified(Self.noSignal, atHz: 7_100_000) == nil)
        #expect(m.bookmarks.count == before + 2)
        #expect(!SignalIDText.canBookmark(Self.noSignal))
        #expect(SignalIDText.canBookmark(Self.tooWeak) && SignalIDText.canBookmark(Self.familyOnly))
    }

    /// HamItUp on: the frequencies stay display Hz (the signal's 14.080 MHz, not the hardware's LO-shifted one) and the
    /// bookmark records the HamItUp state as `addBookmark` does.
    @Test func bookmarkKeepsDisplayHzAndHamItUp() throws {
        let m = idleModel()
        defer { m.shutdown() }
        m.setUpconverter(true)
        let id = try #require(m.bookmarkIdentified(Self.rtty, atHz: 14_080_000))
        let b = try #require(m.bookmarks.first { $0.id == id })
        #expect(b.upconverter)
        #expect(abs(b.frequencyHz - 14_080_000) < 2_000)
        m.tuneToIdentified(Self.rtty, atHz: 14_080_000)
        #expect(m.upconverter.enabled)
        #expect(abs(m.vfoHz - b.frequencyHz) < 1)
    }

    @Test func copyTextHasLabelAndParameters() {
        let text = SignalIDText.copyText(Self.rtty, atHz: 14_080_000)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first == "RTTY · 45.45 Bd · 170 Hz shift · 91%")
        #expect(lines.contains("Frequency: 14.080.000 Hz"))
        #expect(lines.contains("Symbol rate: 45.45 Bd"))
        #expect(lines.contains("Shift: 170 Hz"))
        #expect(lines.contains("SNR: 22 dB"))
        #expect(SignalIDText.copyText(Self.tooWeak, atHz: 7_000_000).hasPrefix("Too weak to identify (SNR 2 dB)"))
    }

    // MARK: The service's card

    @Test func serviceOpensAndClosesTheCard() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let snap = Self.snapshot(seconds: 3.1)
        m.signalID.snapshotProvider = Self.provider(snap)
        m.signalID.chunkProvider = Self.chunks(snap)
        let hold = Locked(true)
        m.signalID.analysis = Self.rtty(needsLongerRead: true, firstAfter: 0.3, holdLongerRead: hold)
        let hz = m.centerHz + 4_000
        m.signalID.openCard(at: CGPoint(x: 400, y: 100), hz: hz)
        var card = try #require(m.signalID.card)
        #expect(card.pending && card.identity == nil && card.point == CGPoint(x: 400, y: 100))
        #expect(await eventually { m.signalID.card?.identity != nil })
        card = try #require(m.signalID.card)
        #expect(card.measuring && !card.pending)
        hold.withLock { $0 = false }
        #expect(await eventually { m.signalID.card?.measuring == false })
        card = try #require(m.signalID.card)
        #expect(card.identity?.best?.name == "RTTY")
        // The card is for the signal's centre (the capture centre plus the measured offset).
        #expect(abs(card.signalHz - hz) < 1e-6)
        m.signalID.closeCard()
        #expect(m.signalID.card == nil)
    }

    @Test func cardWithNoRadioSaysSo() async throws {
        let m = idleModel()
        defer { m.shutdown() }
        m.signalID.openCard(at: CGPoint(x: 10, y: 10), hz: 7_000_000)
        #expect(await eventually { m.signalID.card?.pending == false })
        let card = try #require(m.signalID.card)
        #expect(card.identity == nil && card.signalHz == 7_000_000)
    }

    // MARK: Right-click

    private func event(_ type: NSEvent.EventType, at p: NSPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func clickView(box: (lower: Double, upper: Double)?, cardAt: Locked<[CGPoint]>,
                           locked: Locked<[Double]>) -> SpectrumMTKView {
        let view = SpectrumMTKView(frame: NSRect(x: 0, y: 0, width: 1000, height: 400), device: nil)
        view.interaction = SpectrumInteraction(
            zoom: { _, _ in }, pan: { _ in }, click: { _ in }, reset: {}, hover: { _, _ in },
            passbandEdges: { nil }, dragEdge: { _, _ in }, boxGrabRect: { nil }, boxRange: { box },
            dragBox: { _ in }, clickInBox: { f in locked.withLock { $0.append(f) } },
            rightClick: { unit, size in cardAt.withLock { $0.append(CGPoint(x: unit.x * size.width, y: unit.y * size.height)) } })
        return view
    }

    /// Right-click opens the card anywhere; inside the decoder box it locks the decoder cursor as well. Ctrl-click
    /// is a right-click.
    @Test func rightClickOpensTheCardAndInsideTheBoxStillLocks() {
        let cards = Locked<[CGPoint]>([]), locks = Locked<[Double]>([])
        let view = clickView(box: (0.4, 0.6), cardAt: cards, locked: locks)

        view.rightMouseDown(with: event(.rightMouseDown, at: NSPoint(x: 100, y: 300)))   // outside the box
        #expect(cards.withLock { $0 } == [CGPoint(x: 100, y: 100)])
        #expect(locks.withLock { $0 }.isEmpty)

        view.rightMouseDown(with: event(.rightMouseDown, at: NSPoint(x: 500, y: 300)))   // inside the box
        #expect(cards.withLock { $0.count } == 2)
        #expect(locks.withLock { $0 } == [0.5])

        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 550, y: 300), flags: .control))   // ctrl-click
        #expect(cards.withLock { $0.count } == 3)
        #expect(locks.withLock { $0 } == [0.5, 0.55])

        // A plain left click opens nothing (it tunes, on the mouse up).
        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 100, y: 300)))
        #expect(cards.withLock { $0.count } == 3)
    }

    // MARK: Drawn

    /// The folder the PNGs go to: `SIGNAL_ID_UI_PNG_DIR` when set, else a temporary one.
    private static var outputFolder: URL {
        if let path = ProcessInfo.processInfo.environment["SIGNAL_ID_UI_PNG_DIR"] {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("signal-id-ui-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func png(_ rep: NSBitmapImageRep) -> Data? { rep.representation(using: .png, properties: [:]) }

    /// The card, in an AppKit host (its buttons are AppKit controls) under `appearance`.
    private func render(card identity: SignalIdentity?, pending: Bool = false, measuring: Bool = false,
                        atHz: Double, dark: Bool, model: AppModel) throws -> NSBitmapImageRep {
        let root = SignalIDCard(identity: identity, atHz: atHz, pending: pending, measuring: measuring)
            .environment(model)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Pixels that differ from the corner's, over a coarse grid.
    private func inked(_ rep: NSBitmapImageRep) -> Int {
        guard let corner = rep.colorAt(x: 0, y: 0) else { return 0 }
        var n = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if abs(c.redComponent - corner.redComponent) + abs(c.greenComponent - corner.greenComponent)
                    + abs(c.blueComponent - corner.blueComponent) > 0.15 { n += 1 }
            }
        }
        return n
    }

    @Test func cardRenders() async throws {
        let m = idleModel()
        defer { m.shutdown() }
        let folder = Self.outputFolder
        let cases: [(String, SignalIdentity?, Bool, Bool, Double)] = [
            ("named", Self.rtty, false, false, 14_080_000),
            ("named-measuring", Self.rtty, false, true, 14_080_000),
            ("family-only", Self.familyOnly, false, false, 7_097_000),
            ("too-weak", Self.tooWeak, false, false, 7_105_000),
            ("no-signal", Self.noSignal, false, false, 7_105_000),
            ("identifying", nil, true, false, 7_105_000),
            ("unavailable", nil, false, false, 7_105_000),
        ]
        // The three identities the card is for; the rest of the states only when pictures are asked for.
        let wanted = ProcessInfo.processInfo.environment["SIGNAL_ID_UI_PNG_DIR"] != nil
            ? cases : cases.filter { ["named", "family-only", "too-weak"].contains($0.0) }
        for (name, identity, pending, measuring, hz) in wanted {
            var drawn: [Bool: NSBitmapImageRep] = [:]
            for dark in [false, true] {
                let rep = try render(card: identity, pending: pending, measuring: measuring, atHz: hz, dark: dark,
                                     model: m)
                #expect(rep.pixelsWide >= 280 && rep.pixelsHigh >= 80, "\(name): \(rep.pixelsWide)×\(rep.pixelsHigh)")
                #expect(inked(rep) > 100, "\(name) \(dark ? "dark" : "light")")
                try #require(png(rep)).write(to: folder.appendingPathComponent("card-\(name)-\(dark ? "dark" : "light").png"))
                drawn[dark] = rep
                try await Task.sleep(for: .milliseconds(15))   // the main actor is let go between drawings
            }
            // Light and dark are different pictures.
            #expect(png(drawn[false]!) != png(drawn[true]!), "\(name)")
        }
    }

    @Test func hoverLineRenders() async throws {
        let folder = Self.outputFolder
        let cases: [(String, [String])] = [
            ("named", ["14.080.000   -62.0 dB", "RTTY · 45.45 Bd · 170 Hz shift · 91%"]),
            ("measuring", ["14.080.000   -62.0 dB", "RTTY · 45.45 Bd · 170 Hz shift · 91% · measuring…"]),
            ("pending", ["14.080.000   -62.0 dB", "Identifying…"]),
            ("too-weak", ["7.105.000   -101.5 dB", "Too weak to identify (SNR 2 dB)"]),
            ("plain", ["7.105.000"]),
        ]
        let wanted = ProcessInfo.processInfo.environment["SIGNAL_ID_UI_PNG_DIR"] != nil
            ? cases : cases.filter { ["named", "too-weak"].contains($0.0) }
        for (name, lines) in wanted {
            for dark in [false, true] {
                let view = Canvas { ctx, size in
                    HoverLabelDrawing.draw(ctx, in: size, at: CGPoint(x: 40, y: 60), lines: lines)
                }
                .frame(width: 420, height: 90)
                .background(Theme.spectrumBackground)
                .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.nsImage)
                let tiff = try #require(image.tiffRepresentation)
                let rep = try #require(NSBitmapImageRep(data: tiff))
                #expect(inked(rep) > 50, "\(name)")
                try #require(png(rep)).write(to: folder.appendingPathComponent("hover-\(name)-\(dark ? "dark" : "light").png"))
                try await Task.sleep(for: .milliseconds(15))
            }
        }
    }
}
