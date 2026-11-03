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
/// One test at a time: most run the demo radio (a core each in a debug build), and two dozen of them at once beside
/// the rest of the suite starved it (I2, ruling R32).
@MainActor
@Suite(.serialized)
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

    /// Waits (letting the main actor run) until `condition` holds or `seconds` pass. The bound only ends a failing
    /// wait: one that holds returns at once, however loaded the run (I2).
    private func eventually(_ seconds: Double = 120, _ condition: () -> Bool) async -> Bool {
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

    /// A stub analysis: a 250 Hz RTTY centred where it was asked, counting its runs. With `holdFirst` the first pass,
    /// with `holdLongerRead` the longer read's analysis, waits until that flag is cleared: a state the test holds,
    /// never one it has to catch in a window. A wait ends too when its identification is cancelled (the service runs
    /// one at a time: a cancelled one must not hold the next), or after 120 s.
    private static func rtty(runs: Locked<Int>? = nil, needsLongerRead: Bool = false, holdFirst: Locked<Bool>? = nil,
                             holdLongerRead: Locked<Bool>? = nil) -> SignalIDService.Analysis {
        { a in
            let (centre, at, longer) = (a.captureCenterHz, a.atHz, a.longer)
            runs?.withLock { $0 += 1 }
            if let hold = longer == nil ? holdFirst : holdLongerRead {
                let deadline = Date().addingTimeInterval(120)
                while hold.withLock({ $0 }), !Task.isCancelled, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
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

    static let noSignal = SignalIdentity(measurement: SignalMeasurement(offsetHz: 5_000, family: .noise, seconds: 3),
                                         note: "No signal")

    // MARK: Several signals, and the new evidence

    /// An FT8 member of a group, `offsetHz` from the group's capture centre: measured and named, or (`inherited`)
    /// named only from its neighbour, or unknown.
    static func member(_ offsetHz: Double, named: Bool = true, inherited: Bool = false) -> SignalIdentity {
        let m = SignalMeasurement(offsetHz: offsetHz, occupiedBandwidthHz: 50, bandwidth6dBHz: 50, snrDb: 12,
                                  envelope: .bursty, family: named ? .mfsk : .unknown, familyConfidence: 0.8,
                                  symbolRate: named ? 6.25 : nil, toneCount: named ? 8 : nil, seconds: 16)
        if named { return SignalIdentity(measurement: m, best: ModeMatch(name: "FT8", confidence: 0.9, evidence: [])) }
        guard inherited else { return SignalIdentity(measurement: m) }
        return SignalIdentity(measurement: m, alternatives: [ModeMatch(name: "FT8", confidence: 0.65, evidence: [])],
                              nameInherited: true)
    }

    /// Three signals under the point, recentred: their offsets and span are from the group's own capture centre,
    /// 14.070 MHz, while the answer's top-level offset (the point's own, 14.074 MHz) is from the tuning's, 14.000 MHz.
    static let groupCentre = 14_070_000.0
    static var group: SignalIdentity {
        var top = member(4_000)
        top.measurement.offsetHz = 74_000
        top.signals = [member(5_000, named: false), member(4_000), member(4_400, named: false, inherited: true)]
        top.groupSpanHz = 3_975...5_025
        top.captureCenterHz = groupCentre
        return top
    }

    /// A named FT8 with a checked message, slot evidence and the ring's note.
    static var decoded: SignalIdentity {
        var id = member(0)
        id.measurement.offsetHz = 74_000
        id.measurement.slotFits = [SlotFit(periodSeconds: 15, lengthSeconds: 12.64, fit: 0.9, events: 3)]
        id.decodedText = "CQ K1ABC FN42"
        id.confirmedByDecode = true
        id.note = SignalIDDecoding.ringShortNote(30)
        return id
    }

    static let comb = SignalIdentity(measurement: SignalMeasurement(offsetHz: 12_000, occupiedBandwidthHz: 30,
                                                                    bandwidth6dBHz: 20, snrDb: 18, envelope: .steady,
                                                                    family: .carrier, familyConfidence: 0.8, seconds: 3),
                                     comb: CombInfo(spacingHz: 19_300, lineCount: 23))

    /// The card lists each signal: its frequency (the group's centre plus its own offset), its name, a likely name
    /// never shown as a plain one, and a Tune that plans that signal's own tuning.
    @Test func cardListsEachSignal() async throws {
        let m = idleModel()
        defer { m.shutdown() }
        let atHz = 14_074_000.0
        let rows = SignalIDText.members(Self.group, fallbackCenterHz: atHz - Self.group.measurement.offsetHz)
        #expect(rows.map(\.hz) == [14_074_000, 14_074_400, 14_075_000])
        #expect(rows.map(\.name) == ["FT8 · 90%", "likely FT8 · not measured", "Unknown · 50 Hz"])
        #expect(!rows.contains { $0.name == "FT8" })
        // The span is the group's own centre's too.
        #expect(SignalIDText.groupSpanHz(Self.group, fallbackCenterHz: 14_000_000) == 14_073_975...14_075_025)
        // Without a centre of its own, the fallback.
        var plain = Self.group
        plain.captureCenterHz = nil
        #expect(SignalIDText.members(plain, fallbackCenterHz: 14_000_000).first?.hz == 14_004_000)

        // Each row's Tune is that signal's own plan, at its own frequency.
        for row in rows {
            m.setMode(.am)
            m.tuneToMember(row)
            let plan = SignalIDTuning.plan(for: row.identity, atHz: row.hz)
            #expect(m.mode == plan.demod && abs(m.vfoHz - plan.vfoHz) < 1, "\(row.name)")
            #expect(m.displayedPassband.contains(row.hz), "\(row.name)")
        }
        // The copy has them too.
        let copy = SignalIDText.copyText(Self.group, atHz: atHz)
        #expect(copy.contains("14.074.400 Hz: likely FT8 · not measured"), "\(copy)")

        // Drawn: the rows make the card taller than the same signal alone.
        var alone = Self.group
        alone.signals = []
        alone.groupSpanHz = nil
        let listed = try render(card: Self.group, atHz: atHz, dark: false, model: m)
        let single = try render(card: alone, atHz: atHz, dark: false, model: m)
        #expect(listed.pixelsHigh > single.pixelsHigh + 40, "\(listed.pixelsHigh) vs \(single.pixelsHigh)")
    }

    /// Transmissions on a slot mode's UTC slots are evidence on the card, as the identifier counts them, once.
    @Test func cardShowsSlotEvidence() {
        var id = Self.member(0, named: false)
        id.measurement.slotFits = [SlotFit(periodSeconds: 15, lengthSeconds: 12.64, fit: 0.9, events: 3),
                                   SlotFit(periodSeconds: 7.5, lengthSeconds: 4.48, fit: 0.4, events: 3)]
        #expect(SignalIDText.evidence(id).contains("transmissions start on 15 s UTC boundaries"))
        // FT4's grid.
        id.measurement.slotFits = [SlotFit(periodSeconds: 7.5, lengthSeconds: 4.48, fit: 0.8, events: 2)]
        #expect(SignalIDText.evidence(id).first == "transmissions start on 7.5 s UTC boundaries")
        // One event, or a poor fit, is no evidence.
        id.measurement.slotFits = [SlotFit(periodSeconds: 15, lengthSeconds: 12.64, fit: 1, events: 1),
                                   SlotFit(periodSeconds: 7.5, lengthSeconds: 4.48, fit: 0.5, events: 4)]
        #expect(!SignalIDText.evidence(id).contains { $0.contains("UTC boundaries") })
        // A name that counted it already says it (with what it added): not twice.
        var named = Self.member(0)
        named.measurement.slotFits = [SlotFit(periodSeconds: 15, lengthSeconds: 12.64, fit: 0.9, events: 3)]
        named.best?.evidence = ["transmissions start on 15 s UTC boundaries (+0.15)"]
        #expect(SignalIDText.evidence(named).filter { $0.contains("UTC boundaries") }.count == 1)
        // Agents get it too.
        id.measurement.slotFits = [SlotFit(periodSeconds: 15, lengthSeconds: 12.64, fit: 0.9, events: 3)]
        #expect(SignalIDText.evidence(id, notes: false) == ["transmissions start on 15 s UTC boundaries"])
    }

    /// A trial decode's text is on the card as heard on the air, and nowhere among the evidence.
    @Test func cardShowsDecodedText() throws {
        let m = idleModel()
        defer { m.shutdown() }
        var id = Self.member(0)
        id.measurement.offsetHz = 74_000
        id.decodedText = "CQ K1ABC FN42"
        id.confirmedByDecode = true
        let line = try #require(SignalIDText.decodedLine(id))
        #expect(line.contains("CQ K1ABC FN42") && line.lowercased().contains("heard on the air"), "\(line)")
        #expect(!SignalIDText.evidence(id).contains { $0.contains("K1ABC") })
        #expect(SignalIDText.copyText(id, atHz: 14_074_000).contains(line))
        #expect(SignalIDText.decodedLine(Self.member(0)) == nil)
        // Drawn: the decoded text adds to the card.
        var plain = id
        plain.decodedText = nil
        let with = try render(card: id, atHz: 14_074_000, dark: false, model: m)
        let without = try render(card: plain, atHz: 14_074_000, dark: false, model: m)
        #expect(with.pixelsHigh > without.pixelsHigh + 20, "\(with.pixelsHigh) vs \(without.pixelsHigh)")
    }

    /// A 2-FSK whose two tones were seen taking turns says so, in the brief's words, instead of the measurer's.
    @Test func cardShowsTakingTurns() {
        var fsk = Self.familyOnly
        fsk.measurement.notes = ["2 tones 850 Hz apart take turns", "The keying line and the tone runs agree on 75.00 Bd"]
        let lines = SignalIDText.evidence(fsk)
        #expect(lines.first == "the two tones take turns")
        #expect(!lines.contains("2 tones 850 Hz apart take turns"))
        #expect(lines.contains("The keying line and the tone runs agree on 75.00 Bd"))
        // An FSK read only by its numbers makes no such claim.
        #expect(!SignalIDText.evidence(Self.familyOnly).contains("the two tones take turns"))
    }

    /// An interference comb's line is no station: no Bookmark, but Copy works, and its title is the comb.
    @Test func combHasNoBookmark() throws {
        let m = idleModel()
        defer { m.shutdown() }
        let comb = Self.comb
        #expect(!SignalIDText.canBookmark(comb))
        #expect(m.bookmarkIdentified(comb, atHz: 14_012_000) == nil)
        let copy = SignalIDText.copyText(comb, atHz: 14_012_000)
        #expect(copy.hasPrefix("Interference comb · 19.3 kHz spacing"), "\(copy)")
        #expect(copy.contains("Frequency: 14.012.000 Hz"))
        #expect(SignalIDText.evidence(comb).contains { $0.contains("23 lines") && $0.contains("interference") })
        // A station still can be.
        #expect(SignalIDText.canBookmark(Self.rtty))
        _ = try render(card: comb, atHz: 14_012_000, dark: true, model: m)
    }

    /// The ring's reach (30 s at the default pre-roll) is said on the card, each part of the note on its own line.
    @Test func cardSaysHowFarTheRingReached() throws {
        let note = SignalIDDecoding.ringShortNote(30)
        let lines = SignalIDText.noteLines("Read 2.1 s of the 3 s asked for; " + note)
        try #require(lines.count == 3, "\(lines)")
        #expect(lines[1].contains("reached back only 30 s") && lines[1].contains("may not be confirmed"), "\(lines)")
    }

    // MARK: Hover

    /// The dwell is gated, not timed: the first hover's dwell is cancelled by the 10 px move (it is never let go and
    /// its identification never starts, even when the gate opens), and the rest after it starts exactly one. The
    /// 0.5 s itself is Task 7's `dwellSeconds`.
    @Test func hoverWaitsForADwellAndCancels() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let runs = Locked(0)
        let dwells = Locked(0), open = Locked(false)
        m.signalID.snapshotProvider = Self.provider(Self.snapshot(seconds: 3.1))
        // Every identification that starts is a run (the points differ: none reuses another's answer).
        m.signalID.analysis = { a in
            let (centre, at) = (a.captureCenterHz, a.atHz)
            runs.withLock { $0 += 1 }
            return SignalIdentity(measurement: SignalMeasurement(offsetHz: at - centre, family: .noise, seconds: 3),
                                  note: "No signal")
        }
        m.signalID.dwell = {
            dwells.withLock { $0 += 1 }
            while !open.withLock({ $0 }), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }

        m.hover(at: CGPoint(x: 0.500, y: 0.2), viewSize: Self.view)
        #expect(await eventually { dwells.withLock { $0 } == 1 })
        m.hover(at: CGPoint(x: 0.510, y: 0.2), viewSize: Self.view)   // 10 px: the first dwell is cancelled
        #expect(await eventually { dwells.withLock { $0 } == 2 })
        #expect(runs.withLock { $0 } == 0 && !m.signalID.hoverPending)
        open.withLock { $0 = true }                                   // the rest ends the dwell
        #expect(await eventually { m.signalID.hoverIdentity != nil })
        try await Task.sleep(for: .milliseconds(100))                 // a cancelled one would have started by now
        #expect(runs.withLock { $0 } == 1)
        // A move of 1.5 px is the same point: no new dwell.
        m.hover(at: CGPoint(x: 0.5115, y: 0.2), viewSize: Self.view)
        #expect(dwells.withLock { $0 } == 2)
    }

    /// After the first pass asks for a longer read, the first answer is on the line with `measuring` set until the
    /// longer read's answer replaces it.
    @Test func hoverShowsTheFirstAnswerWhileTheLongerReadRuns() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let snap = Self.snapshot(seconds: 3.1)
        m.signalID.snapshotProvider = Self.provider(snap)
        m.signalID.chunkProvider = Self.chunks(snap)
        let holdFirst = Locked(true), hold = Locked(true)
        m.signalID.analysis = Self.rtty(needsLongerRead: true, holdFirst: holdFirst, holdLongerRead: hold)

        m.hover(at: CGPoint(x: 0.5, y: 0.2), viewSize: Self.view)
        #expect(await eventually { m.signalID.hoverPending })
        #expect(!m.signalID.hoverMeasuring && m.signalID.hoverIdentity == nil)
        holdFirst.withLock { $0 = false }
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

    /// SSB voice is tuned by its suppressed carrier (about 300 Hz outside its near edge), not its passband centre.
    @Test func ssbVoiceIsTunedByItsCarrier() {
        func voice(_ family: SignalFamily, width: Double = 2_400) -> SignalIdentity {
            SignalIdentity(measurement: SignalMeasurement(occupiedBandwidthHz: width, snrDb: 25, family: family),
                           best: ModeMatch(name: "SSB voice (USB/LSB)", confidence: 0.9, evidence: []))
        }
        let usb = SignalIDTuning.plan(for: voice(.usb), atHz: 14_200_000)
        #expect(usb.demod == .usb && usb.vfoHz == 14_200_000 - 1_200 - 300)
        let lsb = SignalIDTuning.plan(for: voice(.lsb), atHz: 7_100_000)
        #expect(lsb.demod == .lsb && lsb.vfoHz == 7_100_000 + 1_200 + 300)
        // A sideband family nothing named is the same; a digital mode in USB is not (centred in the passband).
        var unnamed = voice(.usb)
        unnamed.best = nil
        #expect(SignalIDTuning.plan(for: unnamed, atHz: 14_200_000).vfoHz == 14_200_000 - 1_500)
        #expect(SignalIDTuning.plan(for: Self.rtty, atHz: 14_080_000).vfoHz == 14_080_000 - 1_450)
        // The passband from the carrier + 100 Hz covers the voice's far edge.
        let carrier = usb.vfoHz, top = carrier + 100 + (usb.bandwidthHz ?? 0)
        #expect(top >= 14_200_000 + 1_200)
    }

    /// A bookmark of what Tune cannot name (too weak) is where Tune goes: same frequency, same mode.
    @Test func aTooWeakBookmarkReproducesTune() throws {
        let m = idleModel()
        defer { m.shutdown() }
        m.setMode(.usb)
        let id = try #require(m.bookmarkIdentified(Self.tooWeak, atHz: 7_105_000))
        let b = try #require(m.bookmarks.first { $0.id == id })
        #expect(b.frequencyHz == 7_105_000 && b.mode == .usb && b.bandwidthHz == m.bandwidthHz)
        #expect(!SignalIDText.canBookmark(Self.noSignal))
        let tooSoon = SignalIdentity(measurement: SignalMeasurement(family: .noise, seconds: 0.5),
                                     note: "Too soon after tuning — try again")
        #expect(!SignalIDText.canBookmark(tooSoon))
        #expect(SignalIDText.canBookmark(Self.tooWeak))
    }

    /// Wide signals go to a demod whose passband has the room: DRM (10 kHz) to AM, not a clipped USB; NOAA APT
    /// (38 kHz) to WFM, not NFM's 25 kHz.
    @Test func wideSignalsGetAWideEnoughDemod() {
        func named(_ name: String, family: SignalFamily, width: Double) -> SignalIdentity {
            SignalIdentity(measurement: SignalMeasurement(occupiedBandwidthHz: width, snrDb: 20, family: family),
                           best: ModeMatch(name: name, confidence: 0.9, evidence: []))
        }
        let drm = SignalIDTuning.plan(for: named("DRM", family: .ofdm, width: 10_000), atHz: 9_800_000)
        #expect(drm.demod == .am && drm.bandwidthHz == 12_000 && drm.vfoHz == 9_800_000)
        let apt = SignalIDTuning.plan(for: named("NOAA APT", family: .fm, width: 38_000), atHz: 137_620_000)
        #expect(apt.demod == .wfm && (apt.bandwidthHz ?? 0) >= 38_000)
        // Narrow ones keep their own.
        #expect(SignalIDTuning.plan(for: named("NOAA APT", family: .fm, width: 20_000), atHz: 137_620_000).demod == .nfm)
        #expect(SignalIDTuning.plan(for: named("DRM", family: .ofdm, width: 3_000), atHz: 9_800_000).demod == .usb)
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
        #expect(demod("FT8", .fsk, at: 14_074_000) == .usb)
        #expect(demod("FT4", .fsk, at: 14_080_000) == .usb)
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
        m.signalID.analysis = Self.rtty(needsLongerRead: true, holdLongerRead: hold)
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

    /// A retune while the card's longer read runs drops that read: the first answer stays, saying so, and the card
    /// is no longer measuring.
    @Test func aCardWhoseLongerReadIsCutSaysSo() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let snap = Self.snapshot(seconds: 3.1)
        m.signalID.snapshotProvider = Self.provider(snap)
        m.signalID.chunkProvider = Self.chunks(snap)
        let hold = Locked(true)
        m.signalID.analysis = Self.rtty(needsLongerRead: true, holdLongerRead: hold)
        m.signalID.openCard(at: CGPoint(x: 400, y: 100), hz: m.centerHz + 4_000)
        #expect(await eventually { m.signalID.card?.measuring == true })
        m.signalID.retuneBegins()
        m.signalID.retuned(displayCenterHz: m.centerHz)
        hold.withLock { $0 = false }
        #expect(await eventually { m.signalID.card?.measuring == false })
        let card = try #require(m.signalID.card)
        #expect(card.identity?.best?.name == "RTTY")
        #expect(card.identity?.note == SignalIDService.longerReadCutNote, "\(card.identity?.note ?? "no note")")
    }

    @Test func cardWithNoRadioSaysSo() async throws {
        let m = idleModel()
        defer { m.shutdown() }
        m.signalID.openCard(at: CGPoint(x: 10, y: 10), hz: 7_000_000)
        #expect(await eventually { m.signalID.card?.pending == false })
        let card = try #require(m.signalID.card)
        #expect(card.identity == nil && card.signalHz == 7_000_000)
    }

    /// A second right-click is a new card: it has its own id, and the first card's popover being dismissed late
    /// closes nothing of the second's.
    @Test func aSecondCardIsNotClosedByTheFirstsDismissal() async throws {
        guard let m = runningModel() else { return }
        defer { m.shutdown() }
        let snap = Self.snapshot(seconds: 3.1)
        m.signalID.snapshotProvider = Self.provider(snap)
        m.signalID.chunkProvider = Self.chunks(snap)
        m.signalID.analysis = Self.rtty()
        m.signalID.openCard(at: CGPoint(x: 100, y: 50), hz: m.centerHz + 1_000)
        let first = try #require(m.signalID.card)
        #expect(await eventually { m.signalID.card?.identity != nil })
        m.signalID.openCard(at: CGPoint(x: 700, y: 80), hz: m.centerHz + 9_000)
        let second = try #require(m.signalID.card)
        #expect(second.id != first.id && second.point == CGPoint(x: 700, y: 80))
        // Fresh: nothing of the first card's answer, still identifying.
        #expect(second.identity == nil && second.pending && !second.measuring)
        m.signalID.closeCard(id: first.id)   // the first popover's dismissal, after the second opened
        #expect(m.signalID.card?.id == second.id)
        #expect(await eventually { m.signalID.card?.identity != nil })
        #expect(abs((m.signalID.card?.signalHz ?? 0) - (m.centerHz + 9_000)) < 1e-6)
        m.signalID.closeCard(id: second.id)
        #expect(m.signalID.card == nil)
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
            ("group", Self.group, false, false, 14_074_000),
            ("decoded", Self.decoded, false, false, 14_074_000),
            ("comb", Self.comb, false, false, 14_012_000),
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
