import Foundation
import Testing
@testable import SignalID

/// FT8 and FT4 told apart, from their tones and their UTC slots (`SlotEvidence`), and the hints' tolerance for a receiver
/// tuned off.
@Suite(.serialized) struct SlotEvidenceTests {
    /// A read ending `seconds` after a slot boundary, by UTC.
    static func end(_ seconds: Double) -> Date { Date(timeIntervalSince1970: SignalSynth.slotEpoch + seconds) }

    static let ft8 = ModeTable.row("FT8")!
    static let ft4 = ModeTable.row("FT4")!

    static func fit(_ onTimes: [ClosedRange<Double>], readSeconds: Double, endingAt: Double, row: ModeRow) -> Float {
        SlotEvidence.fit(onTimes: onTimes, readEnd: end(endingAt), readSeconds: readSeconds,
                         period: row.slotPeriodSeconds, length: row.slotSeconds)?.fit ?? -1
    }

    /// FT8's transmissions, :00.5–:13.1 and :15.5–:28.1 in a read from :00 to :30, fit its 15 s slots and not FT4's.
    @Test func ft8OnItsSlotsFits() {
        let on = [0.5...13.1, 15.5...28.1]
        #expect(Self.fit(on, readSeconds: 30, endingAt: 30, row: Self.ft8) >= 0.8)
        #expect(Self.fit(on, readSeconds: 30, endingAt: 30, row: Self.ft4) < 0.5)
        let fits = SlotEvidence.all(onTimes: on, readEnd: Self.end(30), readSeconds: 30)
        #expect(fits.count == 2 && fits.first { $0.periodSeconds == 15 }.map { $0.events >= 2 } == true)
    }

    /// FT4's: one starting every 7.5 s and lasting 4.5 s fit its 7.5 s slots, and not FT8's.
    @Test func ft4OnItsSlotsFits() {
        let on = [0.5...5.0, 8.0...12.5, 15.5...20.0]
        #expect(Self.fit(on, readSeconds: 22, endingAt: 22, row: Self.ft4) >= 0.8)
        #expect(Self.fit(on, readSeconds: 22, endingAt: 22, row: Self.ft8) < 0.5)
        let fits = SlotEvidence.all(onTimes: on, readEnd: Self.end(22), readSeconds: 22)
        #expect(fits.first { $0.periodSeconds == 7.5 }.map { $0.fit >= 0.8 && $0.events >= 2 } == true)
    }

    /// An FT4 fragment whose one edge falls in an even 7.5 s slot fits FT8's grid as well as FT4's: each row keeps its
    /// own fit, so FT4's isn't lost to FT8's.
    @Test func eachRowKeepsItsOwnFit() {
        let on = [0.5...3.0]
        let fits = SlotEvidence.all(onTimes: on, readEnd: Self.end(3), readSeconds: 3)
        #expect(Set(fits.map(\.periodSeconds)) == [15, 7.5])
        #expect(fits.allSatisfy { $0.fit == 1 && $0.events == 1 })
        let m = SignalMeasurement(occupiedBandwidthHz: 100, family: .fsk, familyConfidence: 0.8, symbolRate: 12_000 / 576,
                                  toneCount: 4, toneSpacingHz: 12_000 / 576, seconds: 3,
                                  slotFits: fits.map { SlotFit(periodSeconds: $0.periodSeconds, lengthSeconds: $0.lengthSeconds,
                                                               fit: 1, events: 2) })
        let id = SignalIdentifier.identify(m, rfHz: 14_200_000)
        #expect(id.best?.name == "FT4" && id.best?.evidence.contains { $0.contains("7.5 s UTC boundaries") } == true,
                "\(IdentifyTests.describe(id))")
    }

    /// A slot fit adds nothing under 0.75, nor on one event: a lone edge fits FT4's grid by chance two times in three.
    @Test func weakOrLoneTimingAddsNothing() {
        let m = SignalMeasurement(occupiedBandwidthHz: 50, family: .fsk, familyConfidence: 0.8, symbolRate: 6.25 * 1.0475,
                                  toneCount: 8, toneSpacingHz: 6.25, seconds: 12)
        let none = SignalIdentifier.identify(m, rfHz: 14_200_000)
        for (fit, events) in [(Float(0), 3), (0.74, 3), (1, 1)] {
            var timed = m
            timed.slotFits = [SlotFit(periodSeconds: 15, lengthSeconds: Self.ft8.slotSeconds, fit: fit, events: events)]
            let id = SignalIdentifier.identify(timed, rfHz: 14_200_000)
            #expect(id.best == none.best && id.alternatives == none.alternatives,
                    "fit \(fit), \(events) events: \(IdentifyTests.describe(id))")
        }
        // A lone start, random in phase, fits FT4's grid often; one start never brings two events.
        var lone = 0
        for k in 0..<150 {
            let phase = Double(k) * 0.05
            let fit = SlotEvidence.fit(onTimes: [1.0...3.0], readEnd: Self.end(3 + phase), readSeconds: 3, period: 7.5,
                                       length: Self.ft4.slotSeconds)!
            if fit.fit >= SignalIdentifier.minSlotFit { lone += 1 }
            #expect(fit.events <= 1)
        }
        #expect(lone > 50)
    }

    /// The Mac's clock 2 s off either way still fits; 3.5 s off doesn't.
    @Test func clockTwoSecondsOffStillFits() {
        let on = [0.5...13.1, 15.5...28.1]
        for error in [-1.9, 1.9] {
            #expect(Self.fit(on, readSeconds: 30, endingAt: 30 + error, row: Self.ft8) >= 0.8, "\(error) s off")
        }
        #expect(Self.fit([0.5...5.0, 8.0...12.5], readSeconds: 14, endingAt: 14 + 1.9, row: Self.ft4) >= 0.8)
        #expect(Self.fit(on, readSeconds: 30, endingAt: 33.5, row: Self.ft8) < 0.5)
    }

    /// A signal on throughout a read longer than any transmission fits neither, and nor does one on twice as long as
    /// FT8's.
    @Test func continuousSignalDoesntFit() {
        for row in [Self.ft8, Self.ft4] {
            #expect(Self.fit([0...16], readSeconds: 16, endingAt: 16, row: row) == 0)
            #expect(Self.fit([0...30], readSeconds: 30, endingAt: 30, row: row) == 0)
        }
        #expect(Self.fit([0.5...25.8], readSeconds: 30, endingAt: 30, row: Self.ft8) == 0)
        // A read too short to show an edge says nothing.
        #expect(Self.fit([0...3], readSeconds: 3, endingAt: 8, row: Self.ft8) == 0)
    }

    /// No true time, no slot evidence: an FT8 is named from its tones alone.
    @Test func noTimeNoEvidence() {
        #expect(SlotEvidence.fit(onTimes: [0.5...13.1], readEnd: nil, readSeconds: 16, period: 15, length: 12.64) == nil)
        let capture = Self.capture(.ft8(), readSeconds: 8, endInTransmission: 7.5, rfHz: 14_075_500, seed: 1)
        let id = Self.identified(capture, rfHz: 14_075_500, endTime: nil)
        #expect(id.best?.name == "FT8", "\(IdentifyTests.describe(id))")
        #expect(id.measurement.slotFit == nil)
        #expect(!(id.best?.evidence ?? []).contains { $0.contains("UTC") })
    }

    /// A 2-FSK at 170 Hz keyed on FT8's slots, in FT8's frequencies, is never FT8; and a slot fit can't lift a match
    /// whose numbers score under `hintFloor`.
    @Test func timingAloneNeverNames() {
        let keyed = SynthSpec.bursts(.fsk(.init(tones: 2, rate: 45.45, spacingHz: 170)),
                                     .init(periodSeconds: 15, onSeconds: 79 / 6.25, startSeconds: 0.5, rampSeconds: 0.02))
        let capture = Self.capture(keyed, readSeconds: 8, endInTransmission: 7.5, rfHz: 14_075_500, seed: 2)
        let id = Self.identified(capture, rfHz: 14_075_500, endTime: capture.end)
        #expect(id.best?.name != "FT8" && id.best?.name != "FT4", "\(IdentifyTests.describe(id))")

        // FT8's numbers but its speed 5% off: 0.5 on its parameters, inside its frequencies, on its slots.
        let perfect = SlotFit(periodSeconds: 15, lengthSeconds: Self.ft8.slotSeconds, fit: 1, events: 5)
        let close = SignalMeasurement(occupiedBandwidthHz: 50, family: .fsk, familyConfidence: 0.8,
                                      symbolRate: 6.25 * 1.0525, toneCount: 8, toneSpacingHz: 6.25, seconds: 12,
                                      slotFits: [perfect])
        let named = SignalIdentifier.identify(close, rfHz: 14_075_500)
        #expect(named.best == nil, "\(IdentifyTests.describe(named))")
        let offered = named.alternatives.first { $0.name == "FT8" }
        #expect(offered.map { $0.confidence < SignalIdentifier.nameThreshold } ?? true)

        // A 4-FSK at 20.00 Bd (4% slow for FT4), rectangular, keyed on FT4's slots off its frequencies: its timing never
        // carries it over the name threshold. Its numbers alone may (the FT4 row's own softness: its caveat says so).
        // With the matrix: two 16 s reads.
        guard Sweep.full else { return }
        let fsk4 = SynthSpec.bursts(.fsk(.init(tones: 4, rate: 20, spacingHz: 20)),
                                    .init(periodSeconds: 7.5, onSeconds: 105 * 576 / 12_000.0, startSeconds: 0.5,
                                          rampSeconds: 0.01))
        let slow = Self.capture(fsk4, readSeconds: 16, endInTransmission: 4.8, rfHz: 14_200_000, seed: 5)
        let untimed = Self.identified(slow, rfHz: 14_200_000, endTime: nil)
        let timed = Self.identified(slow, rfHz: 14_200_000, endTime: slow.end)
        func ft4(_ id: SignalIdentity) -> Float {
            ([id.best].compactMap { $0 } + id.alternatives).first { $0.name == "FT4" }?.confidence ?? 0
        }
        print("timingAloneNeverNames: 4-FSK 20 Bd on FT4's slots: FT4 \(ft4(untimed)) untimed, \(ft4(timed)) timed")
        #expect(ft4(untimed) >= SignalIdentifier.nameThreshold || ft4(timed) < SignalIdentifier.nameThreshold,
                "untimed: \(IdentifyTests.describe(untimed)); timed: \(IdentifyTests.describe(timed))")
    }

    /// A slot fit raises a match whose tones already fit: FT8's numbers a little off (0.61), outside its frequencies, are
    /// named with its slots and not without.
    @Test func slotFitRaisesAMatchWhoseTonesFit() {
        var m = SignalMeasurement(occupiedBandwidthHz: 50, family: .fsk, familyConfidence: 0.8,
                                  symbolRate: 6.25 * 1.0475, toneCount: 8, toneSpacingHz: 6.25, seconds: 12)
        #expect(SignalIdentifier.identify(m, rfHz: 14_200_000).best == nil)
        m.slotFits = [SlotFit(periodSeconds: 15, lengthSeconds: Self.ft8.slotSeconds, fit: 0.9, events: 4)]
        let id = SignalIdentifier.identify(m, rfHz: 14_200_000)
        #expect(id.best?.name == "FT8", "\(IdentifyTests.describe(id))")
        #expect(id.best?.evidence.contains { $0.contains("15 s UTC boundaries") } == true)
        // FT4's slots don't raise FT8.
        m.slotFits = [SlotFit(periodSeconds: 7.5, lengthSeconds: Self.ft4.slotSeconds, fit: 1, events: 4)]
        #expect(SignalIdentifier.identify(m, rfHz: 14_200_000).best == nil)
    }

    /// Synthetic FT8 and FT4 over 12 s and 4.5 s reads: each named exactly, never the other.
    @Test(arguments: Sweep.full ? Array(UInt64(1)...8) : [1])
    func ft8AndFT4AreToldApart(seed: UInt64) {
        for (name, spec, seconds, rfHz) in [("FT8", SynthSpec.ft8(), 12.0, 14_075_500.0),
                                            ("FT4", SynthSpec.ft4(), 4.5, 14_081_500.0)] {
            let capture = Self.capture(spec, readSeconds: seconds, endInTransmission: seconds - 0.2, rfHz: rfHz, seed: seed)
            let id = Self.identified(capture, rfHz: rfHz, endTime: capture.end)
            #expect(id.best?.name == name, "\(name) seed \(seed): \(IdentifyTests.describe(id))")
            if name == "FT8" { #expect(id.best?.evidence.contains { $0.contains("JS8") } == true) }
            let other = name == "FT8" ? "FT4" : "FT8"
            #expect(!([id.best].compactMap { $0 } + id.alternatives).contains { $0.name == other && $0.confidence >= 0.7 })
        }
    }

    /// The owner's FT8 group sits 1.1 kHz low (14.0731 MHz): FT8's hint still applies there, and the broadcast bands' edges
    /// don't move.
    @Test func offsetBandStillHints() {
        let low = 14_073_100.0
        #expect(!Self.ft8.hints[0].ranges.contains { $0.contains(low) })
        #expect(Self.ft8.hinted(low))
        let broadcast = ModeTable.row("AM voice/broadcast")!.hints[0]
        #expect(broadcast.contains(9_400_000) && !broadcast.contains(9_399_000))
        // Through the identification, with the matrix.
        guard Sweep.full else { return }
        let capture = Self.capture(.ft8(), readSeconds: 8, endInTransmission: 7.5, rfHz: low, seed: 3)
        let id = Self.identified(capture, rfHz: low, endTime: capture.end)
        #expect(id.best?.name == "FT8", "\(IdentifyTests.describe(id))")
        #expect(id.best?.evidence.contains("in the FT8 frequency (+0.15)") == true, "\(IdentifyTests.describe(id))")
    }

    /// The tolerance is the dials' alone, and never reaches another row's own frequencies or JS8's dial: the PSK hint
    /// stops at its segment (below FT8's), RTTY's at its segments, FT8's short of JS8 at 14.078 and of PSK's segment.
    @Test func toleranceStaysOnTheDials() {
        let psk = ModeTable.row("PSK31 / PSK63")!, rtty = ModeTable.row("RTTY")!, ft4 = ModeTable.row("FT4")!
        #expect(psk.hinted(14_072_000) && !psk.hinted(14_074_500) && !psk.hinted(14_073_500))
        #expect(rtty.hinted(14_080_500) && !rtty.hinted(14_079_500) && !rtty.hinted(14_099_500))
        #expect(Self.ft8.hinted(14_077_000) && !Self.ft8.hinted(14_078_500) && !Self.ft8.hinted(14_072_500))
        #expect(Self.ft8.hinted(14_073_500))
        #expect(ft4.hinted(14_083_000) && !ft4.hinted(14_079_000))
        #expect(ModeTable.row("CW")!.hinted(14_069_000) && !ModeTable.row("CW")!.hinted(14_071_500))
    }

    /// A narrow trace measured PSK in FT8's frequencies, whose tones don't read (a real PSK31 here), isn't named PSK on the
    /// quick answer: it asks for the longer read. In PSK's own segment it is named as before.
    @Test func pskInASlotModesFrequenciesWaits() {
        let psk31 = SynthSpec.psk(.init(order: 2, rate: 31.25, shape: .cosine))
        for (rfHz, held) in [(14_075_500.0, true), (14_071_000, false)] {
            let iq = SignalSynth.make(psk31, sampleRate: Self.rate, seconds: 3, snrDb: 15, offsetHz: Self.offsetHz, seed: 6)
            let id = SignalIdentifier.identify(iq: iq, sampleRate: Self.rate, captureCenterHz: rfHz - Self.offsetHz,
                                               atHz: rfHz, bandwidthHz: nil, spectrumDb: nil, longer: nil)
            if held {
                #expect(id.best == nil && id.needsLongerRead, "\(rfHz): \(IdentifyTests.describe(id))")
                #expect(id.alternatives.contains { $0.name == "PSK31 / PSK63" && $0.confidence < 0.7 },
                        "\(rfHz): \(IdentifyTests.describe(id))")
            } else {
                #expect(id.best?.name == "PSK31 / PSK63", "\(rfHz): \(IdentifyTests.describe(id))")
            }
        }
    }

    /// Synthetic FT8 at 14.200 MHz, outside its frequencies, read over a whole transmission with a true time: named FT8, its
    /// slots among the evidence.
    @Test func ft8OutsideItsBandStillNamedWithSlots() {
        let capture = Self.capture(.ft8(), readSeconds: 16, endInTransmission: 13, rfHz: 14_200_000, seed: 4)
        let id = Self.identified(capture, rfHz: 14_200_000, endTime: capture.end)
        #expect(id.best?.name == "FT8", "\(IdentifyTests.describe(id))")
        #expect(id.measurement.slotFit?.periodSeconds == 15)
        #expect(id.best?.evidence.contains { $0.contains("15 s UTC boundaries") } == true, "\(IdentifyTests.describe(id))")
    }

    // MARK: Captures

    struct Capture {
        var first: [Float]
        var long: [Float]
        var seconds: Double
        var end: Date?
    }

    /// Enough for a narrow mode 3 kHz from the centre, and cheap to make.
    static let rate = 12_000.0
    static let offsetHz = 3000.0

    /// `spec` (a slot mode's bursts) at 10 dB: a read `readSeconds` long ending `endInTransmission` into a transmission, its
    /// newest 3 s, and when it ends by UTC.
    static func capture(_ spec: SynthSpec, readSeconds: Double, endInTransmission: Double, rfHz: Double,
                        seed: UInt64) -> Capture {
        guard case .bursts(let inner, var bursts) = spec else { fatalError("a slot mode's bursts") }
        let end = bursts.startSeconds + endInTransmission
        bursts.captureStartSeconds = (end - readSeconds).truncatingRemainder(dividingBy: bursts.periodSeconds)
            + bursts.periodSeconds
        let placed = SynthSpec.bursts(inner, bursts)
        let long = SignalSynth.make(placed, sampleRate: rate, seconds: readSeconds, snrDb: 10, offsetHz: offsetHz,
                                    seed: seed)
        return Capture(first: Array(long.suffix(2 * Int(3 * rate))), long: long, seconds: readSeconds,
                       end: SignalSynth.endTime(placed, seconds: readSeconds))
    }

    static func identified(_ c: Capture, rfHz: Double, endTime: Date?) -> SignalIdentity {
        SignalIdentifier.identify(iq: c.first, sampleRate: rate, captureCenterHz: rfHz - offsetHz, atHz: rfHz,
                                  bandwidthHz: nil, spectrumDb: nil, longer: { (c.long, c.seconds) }, endTime: endTime)
    }
}
