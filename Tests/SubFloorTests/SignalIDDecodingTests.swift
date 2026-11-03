import Accelerate
import DSPCore
import Foundation
import Modems
import Recording
import SDRplayKit
import SignalID
import SubFloorCore
import Synchronization
import Testing
@testable import SubFloor

/// A value shared with the closures the service runs off the main actor.
private final class Shared<Value: Sendable>: Sendable {
    private let value: Mutex<Value>
    init(_ value: Value) { self.value = Mutex(value) }
    func withLock<R>(_ body: (inout Value) -> R) -> R { value.withLock { body(&$0) } }
}

/// Task 8: Signal ID's trial decodes (`SignalIDDecoding`), for the card and agents. The ring is a buffer of encoder audio
/// made IQ (`iq`) handed over a piece at a time; the identity is the identifier's where the name matters, else made by
/// hand. The service's own tests (hover, card, scan, retune) run a demo-source model with a stub analysis, as
/// `SignalIDServiceTests` do, one at a time.
@MainActor
@Suite(.serialized)
struct SignalIDDecodingTests {
    nonisolated static let rate = 48_000.0
    /// A slot boundary (UTC), and the ring's newest sample 2 s into the next slot.
    nonisolated static let slotStart = Date(timeIntervalSince1970: 1_793_550_000)
    nonisolated static let ringEnd = slotStart.addingTimeInterval(17)
    nonisolated static let ft8Centre = 14_074_000.0

    // MARK: Signals

    /// Real audio at `rate` as IQ: its analytic signal (a Hilbert FIR), moved up `shiftHz`, with complex Gaussian noise
    /// of `noise` RMS per component.
    nonisolated static func iq(audio: [Float], shiftHz: Double, noise: Float = 0.002, seed: UInt64 = 1) -> [Float] {
        let m = 64
        var h = [Float](repeating: 0, count: 2 * m + 1)
        for k in -m...m where k % 2 != 0 {
            let w = 0.42 + 0.5 * cos(Double.pi * Double(k) / Double(m + 1)) + 0.08 * cos(2 * Double.pi * Double(k) / Double(m + 1))
            h[k + m] = Float(2 / (Double.pi * Double(k)) * w)
        }
        let reversed = Array(h.reversed())
        let padded = [Float](repeating: 0, count: m) + audio + [Float](repeating: 0, count: m)
        var q = [Float](repeating: 0, count: audio.count)
        vDSP_conv(padded, 1, reversed, 1, &q, 1, vDSP_Length(audio.count), vDSP_Length(h.count))
        var out = [Float](repeating: 0, count: 2 * audio.count)
        var state = seed &* 0x9E37_79B9_7F4A_7C15
        func uniform() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53) + 1e-12
        }
        let step = 2 * Double.pi * shiftHz / rate
        for n in audio.indices {
            let phase = step * Double(n)
            let (c, s) = (Float(cos(phase)), Float(sin(phase)))
            let r = sqrt(-2 * log(uniform())), a = 2 * Double.pi * uniform()
            out[2 * n] = audio[n] * c - q[n] * s + noise * Float(r * cos(a))
            out[2 * n + 1] = audio[n] * s + q[n] * c + noise * Float(r * sin(a))
        }
        return out
    }

    /// A ring handing over the newest of `iq` (all of it when shorter than asked for), ending at `endTime`.
    nonisolated static func chunks(_ iq: [Float], endTime: Date = ringEnd) -> SignalIDService.ChunkProvider {
        { lastSeconds, chunkFrames, visit in
            let frames = min(iq.count / 2, Int((lastSeconds * rate).rounded()))
            let newest = iq.suffix(2 * frames)
            var start = newest.startIndex
            while start < newest.endIndex {
                let end = min(start + 2 * max(1, chunkFrames), newest.endIndex)
                guard newest[start..<end].withUnsafeBufferPointer(visit) else { return nil }
                start = end
            }
            return IQRead(frames: frames, sampleRate: rate, endTime: endTime)
        }
    }

    nonisolated static func snapshots(_ iq: [Float], endTime: Date = ringEnd) -> SignalIDService.SnapshotProvider {
        { lastSeconds in
            let frames = min(iq.count / 2, Int((lastSeconds * rate).rounded()))
            return IQSnapshot(samples: Array(iq.suffix(2 * frames)), sampleRate: rate, endTime: endTime)
        }
    }

    /// FT8 stations (message, tone 0 in Hz above the capture centre) in the slot at `slotStart` and the one after, in
    /// a ring of `seconds` ending at `ringEnd`.
    nonisolated static func ft8Ring(_ stations: [(String, Double)], seconds: Double = 20,
                                    endTime: Date = ringEnd) -> [Float] {
        let first = endTime.addingTimeInterval(-seconds)
        var audio = [Float](repeating: 0, count: Int(seconds * rate))
        for slot in [slotStart.addingTimeInterval(-15), slotStart, slotStart.addingTimeInterval(15)] {
            let at = Int((slot.timeIntervalSince(first) * rate).rounded())
            for (message, hz) in stations {
                guard let wave = FT8Encoder.audio(message: message, audioHz: hz, sampleRate: rate, amplitude: 0.1) else {
                    continue
                }
                for (i, x) in wave.enumerated() where at + i >= 0 && at + i < audio.count { audio[at + i] += x }
            }
        }
        return iq(audio: audio, shiftHz: 0)
    }

    /// A measured FT8 at `toneZeroHz` above `ft8Centre`, named on its tones (not yet proved).
    nonisolated static func ft8Identity(toneZeroHz: Double, named: Bool = true) -> SignalIdentity {
        let m = SignalMeasurement(offsetHz: toneZeroHz + 3.5 * FT8Encoder.toneSpacing, occupiedBandwidthHz: 50,
                                  bandwidth6dBHz: 45, family: .fsk, familyConfidence: 0.8, symbolRate: 6.25,
                                  toneCount: 8, toneSpacingHz: 6.25, seconds: 16)
        let match = ModeMatch(name: "FT8", confidence: named ? 0.82 : 0.65, evidence: ["its tones"])
        return named ? SignalIdentity(measurement: m, best: match) : SignalIdentity(measurement: m, alternatives: [match])
    }

    /// The identifier on the newest 3 s of `iq` (centred on `centerHz`) at `atHz`, as the card's first pass sees it.
    nonisolated static func identified(_ iq: [Float], centerHz: Double, atHz: Double) -> SignalIdentity {
        let three = Array(iq.suffix(2 * Int(3 * rate)))
        return SignalIdentifier.identify(iq: three, sampleRate: rate, captureCenterHz: centerHz, atHz: atHz,
                                         bandwidthHz: nil, spectrumDb: nil, longer: nil)
    }

    /// The trial for `identity` through the service's own form, on `chunks`, in a tuning centred on `centerHz`.
    nonisolated static func trial(_ identity: SignalIdentity, centerHz: Double, chunks: SignalIDService.ChunkProvider,
                                  trueTime: Bool = true, known: [SignalIDDecoding.SlotDecodes] = [],
                                  decoders: SignalIDDecoding.Decoders = .standard)
        -> (made: SignalIDDecoding.Attempt?, identity: SignalIdentity) {
        let barrier = TuneBarrier()
        barrier.end(centerHz: centerHz)
        guard let plan = SignalIDDecoding.plan(for: identity, centerHz: centerHz) else { return (nil, identity) }
        let made = SignalIDDecoding.attempt(for: identity, plan: plan, state: barrier.current, trueTime: trueTime,
                                            known: known, chunks: chunks, barrier: barrier, decoders: decoders,
                                            cancelled: { false })
        return (made, made.map { SignalIDDecoding.applied($0, to: identity, centerHz: centerHz) } ?? identity)
    }

    // MARK: FT8

    /// A checked message names the FT8 it lies on at 1.0, its text kept; a message beside no trace names nothing, and a
    /// trace with no message of its own keeps what it had.
    @Test func ft8DecodeConfirms() throws {
        let ring = Self.ft8Ring([("CQ K1ABC FN42", 1000), ("G4XYZ K1ABC -12", 1200)])
        let chunks = Self.chunks(ring)
        let own = Self.ft8Identity(toneZeroHz: 1000)
        // A group under the point: the two stations, and a trace between them that is neither (likely FT8, inherited).
        var group = own
        var between = Self.ft8Identity(toneZeroHz: 1100, named: false)
        between.nameInherited = true
        group.signals = [own, between, Self.ft8Identity(toneZeroHz: 1200)]
        group.groupSpanHz = 1000...1250
        group.captureCenterHz = Self.ft8Centre
        // The one decode of the slot (a debug build takes some seconds over it); the rest use it, as a scan would.
        let (made, named) = Self.trial(group, centerHz: Self.ft8Centre, chunks: chunks)
        let slot = try #require(made?.slot)
        #expect(made?.decodes.count == 2 && slot.slotStart == Self.slotStart)
        #expect(named.best?.name == "FT8" && named.best?.confidence == 1)
        #expect(named.confirmedByDecode && named.decodedText == "CQ K1ABC FN42" && !named.needsLongerRead)
        #expect(named.signals[0].decodedText == "CQ K1ABC FN42" && named.signals[0].best?.confidence == 1)
        #expect(named.signals[2].decodedText == "G4XYZ K1ABC -12" && named.signals[2].best?.confidence == 1)
        // Nothing decoded on the trace between them: it is as it was.
        #expect(named.signals[1] == between)
        #expect(named.label.hasPrefix("Several signals: FT8 ×2, unknown ×1") || named.label.hasPrefix("FT8 · 3 signals"),
                "\(named.label)")

        // The plain form: the decode at the signal.
        let decode = try #require(SignalIDDecoding.attempt(for: own, atHz: Self.ft8Centre + own.measurement.offsetHz,
                                                           centerHz: Self.ft8Centre, chunks: chunks, known: [slot],
                                                           cancelled: { false }))
        #expect(decode.mode == "FT8" && decode.strength == .checked && decode.text == "CQ K1ABC FN42")
        #expect(abs(decode.rfHz - (Self.ft8Centre + own.measurement.offsetHz)) < 2)

        // A trace beside the stations (its extent and a tone short of either) is never named by their messages.
        let beside = Self.ft8Identity(toneZeroHz: 1100)
        let (_, alone) = Self.trial(beside, centerHz: Self.ft8Centre, chunks: chunks, known: [slot])
        #expect(alone.best?.confidence == 0.82 && alone.decodedText == nil && !alone.confirmedByDecode)
        // Its extent and a tone: a trace 30 Hz off a message (25 Hz half its width, and 6.25) is named by it; 40 Hz off,
        // not.
        let (_, near) = Self.trial(Self.ft8Identity(toneZeroHz: 1030), centerHz: Self.ft8Centre, chunks: chunks,
                                   known: [slot])
        #expect(near.decodedText == "CQ K1ABC FN42" && near.best?.confidence == 1)
        let (_, off) = Self.trial(Self.ft8Identity(toneZeroHz: 1040), centerHz: Self.ft8Centre, chunks: chunks,
                                  known: [slot])
        #expect(off.decodedText == nil && off.best?.confidence == 0.82)
        // Nor a comb's line, though a message lies on it.
        var line = own
        line.comb = CombInfo(spacingHz: 1000, lineCount: 9)
        let (_, comb) = Self.trial(line, centerHz: Self.ft8Centre, chunks: chunks, known: [slot])
        #expect(comb.decodedText == nil && comb.best?.confidence == 0.82)
        // Nor one wider than an FT8 can be, though a message lies inside it.
        var wide = own
        wide.measurement.occupiedBandwidthHz = 400
        wide.measurement.bandwidth6dBHz = 400
        let (_, voice) = Self.trial(wide, centerHz: Self.ft8Centre, chunks: chunks, known: [slot])
        #expect(voice.decodedText == nil && voice.best?.confidence == 0.82)
    }

    /// With no complete slot within reach (a 10 s ring), no decode: the name from its tones and slots stands, and the
    /// note says why.
    @Test func ft8NoSlotInReachGoesWithout() {
        let calls = Shared(0)
        var decoders = SignalIDDecoding.Decoders.standard
        decoders.ft8 = { _, _ in calls.withLock { $0 += 1 }; return [] }
        let own = Self.ft8Identity(toneZeroHz: 1000)
        let (made, named) = Self.trial(own, centerHz: Self.ft8Centre,
                                       chunks: Self.chunks(Self.ft8Ring([("CQ K1ABC FN42", 1000)], seconds: 10)),
                                       decoders: decoders)
        #expect(made?.decodes.isEmpty == true && calls.withLock { $0 } == 0)
        #expect(named.best == own.best && named.decodedText == nil)
        #expect(named.note == SignalIDDecoding.noSlotNote)
        // Nor without a true time to place the slot by.
        let (_, untimed) = Self.trial(own, centerHz: Self.ft8Centre, chunks: Self.chunks(Self.ft8Ring([])),
                                      trueTime: false, decoders: decoders)
        #expect(untimed.note == SignalIDDecoding.noTrueTimeNote && calls.withLock { $0 } == 0)
        // A full ring whose newest complete slot started more than `ft8RingSeconds` ago (28.9 s): out of reach.
        let late = Self.slotStart.addingTimeInterval(28.9)
        let (_, far) = Self.trial(own, centerHz: Self.ft8Centre,
                                  chunks: Self.chunks(Self.ft8Ring([], seconds: 31, endTime: late), endTime: late),
                                  decoders: decoders)
        #expect(far.note == SignalIDDecoding.noSlotNote && calls.withLock { $0 } == 0)
    }

    // MARK: RTTY and PSK31

    nonisolated static let fskCentre = 11_688_225.0
    nonisolated static let fskCaptureCentre = 11_685_225.0
    nonisolated static let weather = """
        SECURITE SECURITE GALE WARNING ISSUED 1200 UTC. NORTH SEA WIND SOUTHWEST 6 TO GALE 8 BECOMING WEST LATER. \
        SEA ROUGH. RAIN THEN SHOWERS. VISIBILITY GOOD OCCASIONALLY POOR. OUTLOOK WIND NORTHWEST 5 MODERATE SEAS.
        """

    /// Readable RTTY at 75 Bd and 850 Hz outside the amateur segments is named RTTY, its text kept.
    @Test func rttyReadableNamesOutsideHam() {
        let audio = RTTYEncoder.audio(text: Self.weather, centerHz: 3000, baud: 75, shiftHz: 850, sampleRate: Self.rate,
                                      amplitude: 0.1, leadInSeconds: 0.2)
        let ring = Self.iq(audio: Array(audio.prefix(Int(11 * Self.rate))), shiftHz: 0)
        let first = Self.identified(ring, centerHz: Self.fskCaptureCentre, atHz: Self.fskCentre)
        // Unnamed on its numbers (its 1.5 stop bits read its keying at 7/7.5 of 75 Bd: 70).
        #expect(first.best == nil && first.label.hasPrefix("2-FSK · ") && first.label.contains("850 Hz shift"),
                "\(first.label)")
        let (made, named) = Self.trial(first, centerHz: Self.fskCaptureCentre, chunks: Self.chunks(ring))
        #expect(made?.decodes.first?.strength == .readable)
        #expect(named.best?.name == "RTTY", "\(named.label)")
        #expect(named.label.hasPrefix("RTTY · 75 Bd · 850 Hz shift"), "\(named.label)")
        let text = named.decodedText ?? ""
        #expect(text.contains("GALE WARNING"), "\(text)")
    }

    /// Random bits at the same keying (encrypted traffic) print text that doesn't read: still `2-FSK`, nothing kept.
    @Test func encryptedFSKStaysFSK() {
        let ring = SignalSynth.make(.rtty(baud: 75, shiftHz: 850), sampleRate: Self.rate, seconds: 11, snrDb: 25,
                                    offsetHz: Self.fskCentre - Self.fskCaptureCentre, seed: 4)
        let first = Self.identified(ring, centerHz: Self.fskCaptureCentre, atHz: Self.fskCentre)
        #expect(first.label.hasPrefix("2-FSK · 75 Bd · 850 Hz shift"), "\(first.label)")
        let texts = Shared<[String]>([])
        var decoders = SignalIDDecoding.Decoders.standard
        decoders.stream = { stream, audio in
            let text = SignalIDDecoding.Decoders.standard.stream(stream, audio)
            texts.withLock { $0.append(text) }
            return text
        }
        let (made, named) = Self.trial(first, centerHz: Self.fskCaptureCentre, chunks: Self.chunks(ring),
                                       decoders: decoders)
        #expect(texts.withLock { $0.count } == 1, "the RTTY decoder ran")
        #expect(made?.decodes.isEmpty == true)
        #expect(named == first && named.decodedText == nil)
        #expect(named.label.hasPrefix("2-FSK · 75 Bd · 850 Hz shift"))
    }

    /// PSK31 text decodes and reads: PSK31, its text kept.
    @Test func psk31Readable() {
        let text = "CQ CQ DE K1ABC K1ABC PSE K. HELLO BOB, THANKS FOR THE CALL. NAME HERE IS JOHN, QTH IS NEAR LONDON."
        let audio = PSK31Encoder.audio(text: text, frequencyHz: 2000, sampleRate: Self.rate, leadInSeconds: 0.2,
                                       amplitude: 0.05)
        let ring = Self.iq(audio: Array(audio.prefix(Int(11 * Self.rate))), shiftHz: 0)
        let centre = 14_068_500.0
        let first = Self.identified(ring, centerHz: centre, atHz: centre + 2000)
        let (made, named) = Self.trial(first, centerHz: centre, chunks: Self.chunks(ring))
        #expect(made?.decodes.first?.mode == "PSK31 / PSK63", "\(first.label)")
        #expect(named.best?.name == "PSK31 / PSK63", "\(named.label)")
        #expect((named.decodedText ?? "").contains("DE K1ABC K1ABC PSE K"), "\(named.decodedText ?? "")")
    }

    /// Readable text names only its own mode: PSK31 text on an RTTY-like 2-FSK outside the amateur segments (which
    /// readable RTTY would name) leaves it unnamed, its text kept as heard.
    @Test func readableTextNamesOnlyItsMode() {
        let m = SignalMeasurement(offsetHz: 3000, occupiedBandwidthHz: 400, bandwidth6dBHz: 380, snrDb: 30,
                                  envelope: .steady, family: .fsk, familyConfidence: 0.9, symbolRate: 45.45,
                                  fskShiftHz: 170, toneCount: 2, toneSpacingHz: 170, seconds: 3)
        let identity = SignalIdentifier.identify(m, rfHz: Self.fskCentre)
        #expect(identity.best == nil && identity.alternatives.first?.name == "RTTY")
        let psk = TrialDecode(mode: "PSK31 / PSK63", text: "CQ CQ DE K1ABC K1ABC PSE K", strength: .readable,
                              rfHz: Self.fskCentre)
        let named = SignalIDDecoding.applied(.init(decodes: [psk]), to: identity, centerHz: Self.fskCentre - 3000)
        #expect(named.best == nil && named.decodedText == psk.text)
        var rtty = psk
        rtty.mode = "RTTY"
        (rtty.baud, rtty.shiftHz) = (45.45, 170)
        let named2 = SignalIDDecoding.applied(.init(decodes: [rtty]), to: identity, centerHz: Self.fskCentre - 3000)
        #expect(named2.best?.name == "RTTY")
    }

    /// Radio text is kept as data: control and format characters out, at most `maxTextCharacters`.
    @Test func decodedTextIsCleaned() {
        #expect(SignalIDDecoding.clean("CQ\u{7}\r\nDE\u{202E} K1ABC\u{0}  K") == "CQ DE K1ABC K")
        #expect(SignalIDDecoding.clean(String(repeating: "A", count: 2000)).count == SignalIDDecoding.maxTextCharacters)
    }

    // MARK: The service

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A model running the demo source (never the real RSP), its IQ `ring` with a true time, or nil where the engine
    /// can't start (no audio device: tolerated, as elsewhere). The analysis is `analysis`.
    private func runningModel(ring: [Float], analysis: @escaping SignalIDService.Analysis) -> (AppModel, URL)? {
        let dir = tempDir()
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: UserDefaults(suiteName: UUID().uuidString)!,
                         openRSP: { throw SDRplayError.noDevice }, decodeHistoryFolder: dir)
        m.useSource(.synthetic)
        guard m.isRunning else {
            print("engine did not start (tolerated, no audio device)")
            m.shutdown()
            return nil
        }
        m.signalID.snapshotProvider = Self.snapshots(ring)
        m.signalID.chunkProvider = Self.chunks(ring)
        m.signalID.sourceKind = { .sdrplay }
        m.signalID.analysis = analysis
        m.signalID.dwell = {}
        return (m, dir)
    }

    private func eventually(_ seconds: Double = 120, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return condition() }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// An analysis answering an FT8 at tone 0 `toneZeroHz` above the IQ's centre, whatever the point.
    nonisolated static func ft8Analysis(toneZeroHz: Double = 1000) -> SignalIDService.Analysis {
        { _ in ft8Identity(toneZeroHz: toneZeroHz) }
    }

    /// Hover never decodes; the card, given the same answer, does.
    @Test func hoverNeverDecodes() async throws {
        let calls = Shared(0)
        guard let (m, _) = runningModel(ring: Self.ft8Ring([("CQ K1ABC FN42", 1000)]),
                                        analysis: Self.ft8Analysis()) else { return }
        defer { m.shutdown() }
        m.signalID.decoders.ft8 = { _, _ in calls.withLock { $0 += 1 }; return [] }
        m.signalID.decoders.stream = { _, _ in calls.withLock { $0 += 1 }; return "" }
        let hz = m.centerHz + 1000 + 3.5 * FT8Encoder.toneSpacing
        m.signalID.hover(at: CGPoint(x: 10, y: 10), hz: hz)
        #expect(await eventually { m.signalID.hoverIdentity != nil })
        _ = await m.signalID.identify(atHz: hz, priority: .owner, hover: true)
        _ = await m.signalID.identify(atHz: hz)
        // Not even asked to: a hover's, or a stepped scan's (no longer read).
        _ = await m.signalID.identify(atHz: hz, priority: .owner, hover: true, tryDecode: true)
        _ = await m.signalID.identify(atHz: hz, longerRead: false, tryDecode: true)
        #expect(calls.withLock { $0 } == 0)
        // The card decodes.
        m.signalID.openCard(at: CGPoint(x: 10, y: 10), hz: hz)
        #expect(await eventually { m.signalID.card?.pending == false && m.signalID.card?.measuring == false })
        #expect(calls.withLock { $0 } == 1)
    }

    /// A trial through the service leaves the decoder panel as it was: its settings, its box, its rows and the decode
    /// history (nothing written to its folder).
    @Test func decoderPanelUntouched() async throws {
        guard let (m, dir) = runningModel(ring: Self.ft8Ring([("CQ K1ABC FN42", 1000)]),
                                          analysis: Self.ft8Analysis()) else { return }
        defer { m.shutdown() }
        let settings = m.modemSettings, box = m.modemBox
        let rows = (m.decodeLog.slotRows.count, m.decodeLog.liveRows.count)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        let hz = m.centerHz + 1000 + 3.5 * FT8Encoder.toneSpacing
        // The real stream decoder on the box's audio; FT8's decoder (some seconds in a debug build, and tried in
        // `ft8DecodeConfirms`) gives the message as it would.
        m.signalID.decoders.ft8 = { audio, slotStart in
            _ = SignalIDDecoding.Decoders.standard.stream(.psk31, audio)
            return [SlotDecode(mode: .ft8, slotStart: slotStart, frequencyHz: 1800 - 3.5 * FT8Encoder.toneSpacing,
                               snrDb: 0, timeOffset: 0, message: "CQ K1ABC FN42")]
        }
        let answer = await m.signalID.identify(atHz: hz, priority: .owner, tryDecode: true)
        #expect(answer?.decodedText == "CQ K1ABC FN42" && answer?.best?.confidence == 1)
        m.decodeHistory.flush()
        #expect(m.modemSettings == settings && m.modemBox == box)
        #expect(m.decodeLog.slotRows.count == rows.0 && m.decodeLog.liveRows.count == rows.1)
        #expect(m.decodeHistory.decodes(since: .distantPast).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == files)
    }

    /// A retune while the decode runs drops the answer.
    @Test func retuneDropsTheDecode() async throws {
        guard let (m, _) = runningModel(ring: Self.ft8Ring([]), analysis: Self.ft8Analysis()) else { return }
        defer { m.shutdown() }
        let service = m.signalID
        let barrier = service.tuning
        m.signalID.decoders.ft8 = { _, _ in
            barrier.begin()
            barrier.end(centerHz: 7_074_000)
            return []
        }
        let hz = m.centerHz + 1000 + 3.5 * FT8Encoder.toneSpacing
        let answer = await m.signalID.identify(atHz: hz, priority: .owner, tryDecode: true)
        #expect(answer == nil)
    }

    /// Six traces in one slot's group, identified in turn as a scan does: the slot is decoded once.
    @Test func scanDecodesASlotOnce() async throws {
        let calls = Shared(0)
        let members = (0..<6).map { Self.ft8Identity(toneZeroHz: 600 + 300 * Double($0)) }
        let analysis: SignalIDService.Analysis = { a in
            let near = members.min { abs($0.measurement.offsetHz - (a.atHz - a.captureCenterHz))
                < abs($1.measurement.offsetHz - (a.atHz - a.captureCenterHz)) }!
            var id = near
            id.signals = members
            id.groupSpanHz = 600...2150
            id.captureCenterHz = a.captureCenterHz
            return id
        }
        guard let (m, _) = runningModel(ring: Self.ft8Ring([]), analysis: analysis) else { return }
        defer { m.shutdown() }
        m.signalID.decoders.ft8 = { _, _ in calls.withLock { $0 += 1 }; return [] }
        for member in members {
            _ = await m.signalID.identify(atHz: m.centerHz + member.measurement.offsetHz, tryDecode: true)
        }
        #expect(calls.withLock { $0 } == 1)
    }
}

