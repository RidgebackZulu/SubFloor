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

    /// FT8 stations (message, tone 0 in Hz above the capture centre, the slots it sends in: `slotStart` when none are
    /// given) in a ring of `seconds` ending at `endTime`.
    nonisolated static func ft8Ring(_ stations: [(String, Double, [Date])], seconds: Double = 20,
                                    endTime: Date = ringEnd) -> [Float] {
        let first = endTime.addingTimeInterval(-seconds)
        var audio = [Float](repeating: 0, count: Int(seconds * rate))
        for (message, hz, slots) in stations {
            guard let wave = FT8Encoder.audio(message: message, audioHz: hz, sampleRate: rate, amplitude: 0.1) else {
                continue
            }
            for slot in slots.isEmpty ? [slotStart] : slots {
                let at = Int((slot.timeIntervalSince(first) * rate).rounded())
                for (i, x) in wave.enumerated() where at + i >= 0 && at + i < audio.count { audio[at + i] += x }
            }
        }
        return iq(audio: audio, shiftHz: 0)
    }

    /// One station at 1000 Hz in `slotStart`, for the service's tests: what their FT8 answer (`ft8Analysis`) is.
    nonisolated static let serviceRing = ft8Ring([("CQ K1ABC FN42", 1000, [])])

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
                                  trueTime: Bool = true, known: [SignalIDDecoding.BoxRead] = [],
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

    /// A checked message names the FT8 it lies on at 1.0, its text kept, when that trace was on the air in the message's
    /// slot as the trial's own 45 s read times it; a message beside no trace names nothing, and a trace with no message
    /// of its own keeps what it had. The point is clicked while it sends (8 s into its slot): it is decoded in its
    /// previous own slot, 30 s before, which only a read of a parity period and a slot holds.
    @Test func ft8DecodeConfirms() throws {
        let next = Self.slotStart.addingTimeInterval(15), now = Self.slotStart.addingTimeInterval(30)
        let end = Self.slotStart.addingTimeInterval(38)
        let ring = Self.ft8Ring([
            // The point: sending now, and in its own slot before.
            ("CQ K1ABC FN42", 1000, [Self.slotStart, now]), ("G4XYZ K1ABC -12", 1200, []),
            // Near the box's edge, 1.3 kHz from its middle.
            ("CQ VK2ABC QF56", 2400, []),
            // On the air only in the slot now on (never in a complete slot of the read).
            ("CQ W1AW FN31", 1600, [now]),
            // A line two stations share, one of each parity.
            ("CQ DL1ABC JO62", 1400, [Self.slotStart]), ("CQ JA1XYZ PM95", 1400, [next]),
        ], seconds: 48, endTime: end)
        let chunks = Self.chunks(ring, endTime: end)
        let own = Self.ft8Identity(toneZeroHz: 1000)
        // A group under the point: the two stations, and a trace between them that is neither (likely FT8, inherited).
        var group = own
        var between = Self.ft8Identity(toneZeroHz: 1100, named: false)
        between.nameInherited = true
        group.signals = [own, between, Self.ft8Identity(toneZeroHz: 1200), Self.ft8Identity(toneZeroHz: 2400)]
        group.groupSpanHz = 1000...1250
        group.captureCenterHz = Self.ft8Centre
        // The one decode of the slot (a debug build takes some seconds over it); the rest use the box's read, as a scan
        // would.
        let (made, named) = Self.trial(group, centerHz: Self.ft8Centre, chunks: chunks)
        let box = try #require(made?.box)
        #expect(made?.slotStart == Self.slotStart && box.slots[Self.slotStart]?.count == 4, "\(made?.decodes ?? [])")
        #expect(named.best?.name == "FT8" && named.best?.confidence == 1)
        #expect(named.confirmedByDecode && named.decodedText == "CQ K1ABC FN42" && !named.needsLongerRead)
        #expect(named.signals[0].decodedText == "CQ K1ABC FN42" && named.signals[0].best?.confidence == 1)
        // A member, timed over the trial's read: named with its own message.
        #expect(named.signals[2].decodedText == "G4XYZ K1ABC -12" && named.signals[2].best?.confidence == 1)
        // One near the box's edge too (timed over the whole box).
        #expect(named.signals[3].decodedText == "CQ VK2ABC QF56")
        // Nothing on the trace between them: it is as it was.
        #expect(named.signals[1] == between)
        #expect(named.label.hasPrefix("FT8 · 4 signals"), "\(named.label)")
        func tried(_ identity: SignalIdentity) -> (made: SignalIDDecoding.Attempt?, identity: SignalIdentity) {
            Self.trial(identity, centerHz: Self.ft8Centre, chunks: chunks, known: [box])
        }

        // The plain form: the decode at the signal.
        let decode = try #require(SignalIDDecoding.attempt(for: own, atHz: Self.ft8Centre + own.measurement.offsetHz,
                                                           centerHz: Self.ft8Centre, chunks: chunks, known: [box],
                                                           cancelled: { false }))
        #expect(decode.mode == "FT8" && decode.strength == .checked && decode.text == "CQ K1ABC FN42")
        #expect(abs(decode.rfHz - (Self.ft8Centre + own.measurement.offsetHz)) < 2)

        // A trace beside the stations (nothing on the air there) gets no decode of its own, and no one's message.
        let alone = tried(Self.ft8Identity(toneZeroHz: 1100)).identity
        #expect(alone.best?.confidence == 0.82 && alone.decodedText == nil && alone.note == SignalIDDecoding.noOwnSlotNote)
        // Its extent and a tone: a trace 30 Hz off a message (25 Hz half its width, and 6.25) is named by it; 40 Hz off,
        // not.
        #expect(tried(Self.ft8Identity(toneZeroHz: 1030)).identity.decodedText == "CQ K1ABC FN42")
        let off = tried(Self.ft8Identity(toneZeroHz: 1040)).identity
        #expect(off.decodedText == nil && off.best?.confidence == 0.82)
        // Nor a comb's line, though a message lies on it.
        var line = own
        line.comb = CombInfo(spacingHz: 1000, lineCount: 9)
        let comb = tried(line).identity
        #expect(comb.decodedText == nil && comb.best?.confidence == 0.82)
        // Stations keep a parity. One on the air only in the slot now on is another station: alone, no complete slot of
        // its own is in the read; in a group, it keeps its own answer. A line on in both parities is two stations: never
        // said to be the decoded slot's. And a member at a message's frequency that offers no FT8 is never named it.
        let current = tried(Self.ft8Identity(toneZeroHz: 1600)).identity
        #expect(current.decodedText == nil && current.best?.confidence == 0.82 && current.note == SignalIDDecoding.noOwnSlotNote)
        let shared = tried(Self.ft8Identity(toneZeroHz: 1400)).identity
        #expect(shared.decodedText == nil && shared.note == SignalIDDecoding.noOwnSlotNote)
        var psk = Self.ft8Identity(toneZeroHz: 1200)
        psk.measurement.family = .psk
        psk.best = ModeMatch(name: "PSK31 / PSK63", confidence: 0.8, evidence: [])
        for neighbour in [Self.ft8Identity(toneZeroHz: 1600), Self.ft8Identity(toneZeroHz: 1400), psk] {
            var pair = own
            pair.signals = [own, neighbour]
            pair.captureCenterHz = Self.ft8Centre
            let two = tried(pair).identity
            #expect(two.signals[0].decodedText == "CQ K1ABC FN42")
            #expect(two.signals[1] == neighbour, "\(neighbour.label)")
        }
        // A message whose nearest trace may not be named is no one's: never moved to the next trace it lies on (the point,
        // 25 Hz off). Here the PSK31 member 25 Hz above the point holds the message.
        var probe = own
        var close = psk
        close.measurement.offsetHz = own.measurement.offsetHz + 25
        probe.signals = [own, close]
        probe.captureCenterHz = Self.ft8Centre
        let theirs = TrialDecode(mode: "FT8", text: "K9ZZ W1AW RR73", strength: .checked,
                                 rfHz: Self.ft8Centre + close.measurement.offsetHz)
        var only = try #require(made)
        only.decodes = [theirs]
        let moved = SignalIDDecoding.applied(only, to: probe, centerHz: Self.ft8Centre)
        #expect(moved.decodedText == nil && moved.signals.allSatisfy { $0.decodedText == nil })
        // Nor one wider than an FT8 can be, though a message lies inside it.
        var wide = own
        wide.measurement.occupiedBandwidthHz = 400
        wide.measurement.bandwidth6dBHz = 400
        let voice = tried(wide).identity
        #expect(voice.decodedText == nil && voice.best?.confidence == 0.82)
    }

    /// With no complete slot within reach, no decode: the name from its tones and slots stands, and the note says what
    /// limited it (a 10 s ring; a full 45 s read whose last slot of its own began just before it).
    @Test func ft8NoSlotInReachGoesWithout() {
        let calls = Shared(0)
        var decoders = SignalIDDecoding.Decoders.standard
        decoders.ft8 = { _, _ in calls.withLock { $0 += 1 }; return [] }
        let own = Self.ft8Identity(toneZeroHz: 1000)
        let (made, named) = Self.trial(own, centerHz: Self.ft8Centre,
                                       chunks: Self.chunks(Self.ft8Ring([("CQ K1ABC FN42", 1000, [])], seconds: 10)),
                                       decoders: decoders)
        #expect(made?.decodes.isEmpty == true && calls.withLock { $0 } == 0)
        #expect(named.best == own.best && named.decodedText == nil)
        #expect(named.note == SignalIDDecoding.ringShortNote(10), "\(named.note ?? "")")
        // Nor without a true time to place the slot by.
        let (_, untimed) = Self.trial(own, centerHz: Self.ft8Centre, chunks: Self.chunks(Self.serviceRing),
                                      trueTime: false, decoders: decoders)
        #expect(untimed.note == SignalIDDecoding.noTrueTimeNote && calls.withLock { $0 } == 0)
        // A full ring whose newest complete slot of its own started more than `ft8RingSeconds` ago (45.9 s): out of reach.
        let late = Self.slotStart.addingTimeInterval(45.9)
        let (_, far) = Self.trial(own, centerHz: Self.ft8Centre,
                                  chunks: Self.chunks(Self.ft8Ring([("CQ K1ABC FN42", 1000, [])], seconds: 48, endTime: late),
                                                      endTime: late),
                                  decoders: decoders)
        #expect(far.note == SignalIDDecoding.noOwnSlotNote && calls.withLock { $0 } == 0, "\(far.note ?? "")")
        // A message that is nothing once cleaned is no message.
        var blank = SignalIDDecoding.Decoders.standard
        blank.ft8 = { _, slotStart in
            [SlotDecode(mode: .ft8, slotStart: slotStart, frequencyHz: 1000, snrDb: 0, timeOffset: 0, message: "\u{7}\u{0}")]
        }
        let (empty, _) = Self.trial(own, centerHz: Self.ft8Centre, chunks: Self.chunks(Self.serviceRing), decoders: blank)
        #expect(empty?.decodes.isEmpty == true && empty?.box?.slots[Self.slotStart] == [])
    }

    /// A slot decoded is kept though the job was stopped meanwhile (for the owner): its retry uses it. A retune drops it.
    @Test func aDecodeMadeIsKeptThoughStopped() {
        let stop = Shared(false)
        var decoders = SignalIDDecoding.Decoders.standard
        decoders.ft8 = { _, slotStart in
            stop.withLock { $0 = true }
            return [SlotDecode(mode: .ft8, slotStart: slotStart, frequencyHz: 1000, snrDb: 0, timeOffset: 0,
                               message: "CQ K1ABC FN42")]
        }
        let barrier = TuneBarrier()
        barrier.end(centerHz: Self.ft8Centre)
        let own = Self.ft8Identity(toneZeroHz: 1000)
        let made = SignalIDDecoding.attempt(for: own, plan: .ft8(targetHz: Self.ft8Centre + 1000), state: barrier.current,
                                            trueTime: true, known: [], chunks: Self.chunks(Self.serviceRing),
                                            barrier: barrier, decoders: decoders, cancelled: { stop.withLock { $0 } })
        #expect(made?.box?.slots[Self.slotStart]?.first?.text == "CQ K1ABC FN42")
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

    /// Text counts at `readableScore` and over: text reading 0.4 is no decode, 0.6 is one.
    @Test func readableScoreIsTheBar() throws {
        let words = "CQ CQ DE K1ABC K1ABC PSE K"
        let low = words + " " + String(repeating: "XQZVBWJ ", count: 4), high = words + " XQZVBWJXQZVB"
        #expect((0.35...0.45).contains(ReadableText.score(low)) && (0.55...0.65).contains(ReadableText.score(high)))
        let m = SignalMeasurement(offsetHz: 3000, occupiedBandwidthHz: 1000, bandwidth6dBHz: 1000, snrDb: 30,
                                  envelope: .steady, family: .fsk, familyConfidence: 0.7, symbolRate: 75, fskShiftHz: 850,
                                  toneCount: 2, toneSpacingHz: 850, seconds: 3)
        let identity = SignalIdentifier.identify(m, rfHz: Self.fskCentre)
        let ring = [Float](repeating: 0, count: 2 * Int(4 * Self.rate))
        for (text, decodes) in [(low, false), (high, true)] {
            var decoders = SignalIDDecoding.Decoders.standard
            decoders.stream = { _, _ in text }
            let (made, named) = Self.trial(identity, centerHz: Self.fskCaptureCentre, chunks: Self.chunks(ring),
                                           decoders: decoders)
            #expect((made?.decodes.isEmpty == false) == decodes, "\(text)")
            #expect((named.decodedText != nil) == decodes)
        }
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

    /// A message names the nearest of the traces it lies on, and a trace takes the nearest of the messages on it.
    @Test func aTraceTakesItsNearestMessage() {
        func message(_ text: String, at hz: Double) -> TrialDecode {
            TrialDecode(mode: "FT8", text: text, strength: .checked, rfHz: Self.ft8Centre + hz)
        }
        var wide = Self.ft8Identity(toneZeroHz: 1000)   // centre 1021.875
        wide.measurement.occupiedBandwidthHz = 90
        var group = wide
        group.signals = [wide, Self.ft8Identity(toneZeroHz: 1040)]   // centre 1061.875: overlaps the first
        // Both on the air in the slot (the one station at 1000 Hz overlaps them).
        let map = OnAirMap(iq: Self.serviceRing, sampleRate: Self.rate, centerOffsetHz: 0, halfSpanHz: 2000,
                           readEnd: Self.ringEnd)
        let made = SignalIDDecoding.Attempt(decodes: [message("FIRST", at: 1050), message("SECOND", at: 1025),
                                                      message("THIRD", at: 1010)], slotStart: Self.slotStart, map: map)
        let named = SignalIDDecoding.applied(made, to: group, centerHz: Self.ft8Centre)
        // 1025 and 1010 lie on the first only (36.9 Hz and more from the second's centre: past its 25 and a tone), and
        // 1025 is the nearer: the first's. 1050 lies on both, nearer the second: the second's.
        #expect(named.signals[0].decodedText == "SECOND" && named.decodedText == "SECOND")
        #expect(named.signals[1].decodedText == "FIRST")
    }

    /// Radio text is kept as data: control and format characters out, at most `maxTextCharacters`.
    @Test func decodedTextIsCleaned() {
        #expect(SignalIDDecoding.clean("CQ\u{7}\r\nDE\u{202E} K1ABC\u{0}  K") == "CQ DE K1ABC K")
        #expect(SignalIDDecoding.clean(String(repeating: "A", count: 2000)).count == SignalIDDecoding.maxTextCharacters)
        // The cap is on scalars: combining marks don't stretch it.
        let marks = SignalIDDecoding.clean(String(repeating: "e\u{301}\u{302}", count: 2000))
        #expect(marks.unicodeScalars.count == SignalIDDecoding.maxTextCharacters)
        #expect(!SignalIDDecoding.clean(String(repeating: "A ", count: 600)).hasSuffix(" "))
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
        guard let (m, _) = runningModel(ring: Self.serviceRing,
                                        analysis: Self.ft8Analysis()) else { return }
        defer { m.shutdown() }
        let open = Shared(false)
        m.signalID.decoders.ft8 = { _, _ in
            calls.withLock { $0 += 1 }
            // Held until the card's answer has been seen (a bound, so a decode that shouldn't run fails, not hangs).
            let until = Date().addingTimeInterval(20)
            while !open.withLock({ $0 }), Date() < until { Thread.sleep(forTimeInterval: 0.005) }
            return []
        }
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
        // The card decodes, its answer up meanwhile.
        m.signalID.openCard(at: CGPoint(x: 10, y: 10), hz: hz)
        #expect(await eventually { calls.withLock { $0 } == 1 })
        #expect(await eventually { m.signalID.card?.identity != nil && m.signalID.card?.measuring == true })
        open.withLock { $0 = true }
        #expect(await eventually { m.signalID.card?.pending == false && m.signalID.card?.measuring == false })
        #expect(calls.withLock { $0 } == 1)
    }

    /// A trial through the service leaves the decoder panel as it was: its settings, its box, its rows and the decode
    /// history (nothing written to its folder).
    @Test func decoderPanelUntouched() async throws {
        guard let (m, dir) = runningModel(ring: Self.serviceRing,
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
        guard let (m, _) = runningModel(ring: Self.serviceRing, analysis: Self.ft8Analysis()) else { return }
        defer { m.shutdown() }
        let service = m.signalID
        let barrier = service.tuning
        m.signalID.decoders.ft8 = { _, _ in
            // A retune that comes back to the same centre: the IQ heard before it is still another tuning's.
            let centre = barrier.current.centerHz
            barrier.begin()
            barrier.end(centerHz: centre)
            return []
        }
        let hz = m.centerHz + 1000 + 3.5 * FT8Encoder.toneSpacing
        let answer = await m.signalID.identify(atHz: hz, priority: .owner, tryDecode: true)
        #expect(answer == nil)
        // The card keeps the answer it had, saying the decode (not the longer read) was cut.
        m.signalID.openCard(at: CGPoint(x: 10, y: 10), hz: hz)
        #expect(await eventually { m.signalID.card?.pending == false && m.signalID.card?.measuring == false })
        let note = m.signalID.card?.identity?.note ?? ""
        #expect(note.contains(SignalIDService.trialDecodeCutNote) && !note.contains(SignalIDService.longerReadCutNote),
                "\(note)")
    }

    /// A slot decoded for a caller that went meanwhile (a closed card) is kept: the next point in it uses it.
    @Test func aGoneCallersSlotIsKept() async throws {
        let calls = Shared(0), open = Shared(false)
        guard let (m, _) = runningModel(ring: Self.serviceRing, analysis: Self.ft8Analysis()) else { return }
        defer { m.shutdown() }
        m.signalID.decoders.ft8 = { _, _ in
            calls.withLock { $0 += 1 }
            let until = Date().addingTimeInterval(20)
            while !open.withLock({ $0 }), Date() < until { Thread.sleep(forTimeInterval: 0.005) }
            return []
        }
        let hz = m.centerHz + 1000 + 3.5 * FT8Encoder.toneSpacing
        let service = m.signalID
        let gone = Task { await service.identify(atHz: hz, tryDecode: true) }
        #expect(await eventually { calls.withLock { $0 } == 1 })
        gone.cancel()
        open.withLock { $0 = true }
        #expect(await gone.value == nil)
        _ = await m.signalID.identify(atHz: hz, tryDecode: true)
        #expect(calls.withLock { $0 } == 1)
    }

    /// Six traces in one slot's group, identified in turn as a scan does: the slot is decoded once.
    @Test func scanDecodesASlotOnce() async throws {
        let calls = Shared(0)
        let members = (0..<6).map { Self.ft8Identity(toneZeroHz: 600 + 300 * Double($0)) }
        let analysis: SignalIDService.Analysis = { a in
            // A lone FT8 far from the group, outside the box its slot was decoded in.
            if a.atHz - a.captureCenterHz > 5000 { return SignalIDDecodingTests.ft8Identity(toneZeroHz: 6000) }
            let near = members.min { abs($0.measurement.offsetHz - (a.atHz - a.captureCenterHz))
                < abs($1.measurement.offsetHz - (a.atHz - a.captureCenterHz)) }!
            var id = near
            id.signals = members
            id.groupSpanHz = 600...2150
            id.captureCenterHz = a.captureCenterHz
            return id
        }
        let ring = Self.ft8Ring(members.indices.map { ("CQ K1ABC FN42", 600 + 300 * Double($0), []) }
                                + [("CQ W1AW FN31", 6000, [])])
        guard let (m, _) = runningModel(ring: ring, analysis: analysis) else { return }
        defer { m.shutdown() }
        m.signalID.decoders.ft8 = { _, _ in calls.withLock { $0 += 1 }; return [] }
        for member in members {
            _ = await m.signalID.identify(atHz: m.centerHz + member.measurement.offsetHz, tryDecode: true)
        }
        #expect(calls.withLock { $0 } == 1)
        // One outside that box is decoded in its own.
        _ = await m.signalID.identify(atHz: m.centerHz + 6000 + 3.5 * FT8Encoder.toneSpacing, tryDecode: true)
        #expect(calls.withLock { $0 } == 2)
    }
}

