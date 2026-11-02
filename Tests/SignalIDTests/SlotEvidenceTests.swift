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
        #expect(SlotEvidence.best(onTimes: on, readEnd: Self.end(30), readSeconds: 30)?.periodSeconds == 15)
    }

    /// FT4's: one starting every 7.5 s and lasting 4.5 s fit its 7.5 s slots, and not FT8's.
    @Test func ft4OnItsSlotsFits() {
        let on = [0.5...5.0, 8.0...12.5, 15.5...20.0]
        #expect(Self.fit(on, readSeconds: 22, endingAt: 22, row: Self.ft4) >= 0.8)
        #expect(Self.fit(on, readSeconds: 22, endingAt: 22, row: Self.ft8) < 0.5)
        #expect(SlotEvidence.best(onTimes: on, readEnd: Self.end(22), readSeconds: 22)?.periodSeconds == 7.5)
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
        let perfect = SlotFit(periodSeconds: 15, lengthSeconds: Self.ft8.slotSeconds, fit: 1)
        let close = SignalMeasurement(occupiedBandwidthHz: 50, family: .fsk, familyConfidence: 0.8,
                                      symbolRate: 6.25 * 1.0525, toneCount: 8, toneSpacingHz: 6.25, seconds: 12,
                                      slotFit: perfect)
        let named = SignalIdentifier.identify(close, rfHz: 14_075_500)
        #expect(named.best == nil, "\(IdentifyTests.describe(named))")
        let offered = named.alternatives.first { $0.name == "FT8" }
        #expect(offered.map { $0.confidence < SignalIdentifier.nameThreshold } ?? true)
    }

    /// A slot fit raises a match whose tones already fit: FT8's numbers a little off (0.61), outside its frequencies, are
    /// named with its slots and not without.
    @Test func slotFitRaisesAMatchWhoseTonesFit() {
        var m = SignalMeasurement(occupiedBandwidthHz: 50, family: .fsk, familyConfidence: 0.8,
                                  symbolRate: 6.25 * 1.0475, toneCount: 8, toneSpacingHz: 6.25, seconds: 12)
        #expect(SignalIdentifier.identify(m, rfHz: 14_200_000).best == nil)
        m.slotFit = SlotFit(periodSeconds: 15, lengthSeconds: Self.ft8.slotSeconds, fit: 0.9)
        let id = SignalIdentifier.identify(m, rfHz: 14_200_000)
        #expect(id.best?.name == "FT8", "\(IdentifyTests.describe(id))")
        #expect(id.best?.evidence.contains { $0.contains("15 s UTC boundaries") } == true)
        // FT4's slots don't raise FT8.
        m.slotFit = SlotFit(periodSeconds: 7.5, lengthSeconds: Self.ft4.slotSeconds, fit: 1)
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
        let capture = Self.capture(.ft8(), readSeconds: 8, endInTransmission: 7.5, rfHz: low, seed: 3)
        let id = Self.identified(capture, rfHz: low, endTime: capture.end)
        #expect(id.best?.name == "FT8", "\(IdentifyTests.describe(id))")
        #expect(id.best?.evidence.contains("in the FT8 frequency (+0.15)") == true, "\(IdentifyTests.describe(id))")
        let broadcast = ModeTable.row("AM voice/broadcast")!.hints[0]
        #expect(broadcast.contains(9_400_000) && !broadcast.contains(9_399_000))
    }

    /// Synthetic FT8 at 14.200 MHz, outside its frequencies, read from before a transmission began with a true time: named
    /// FT8, its slots among the evidence.
    @Test func ft8OutsideItsBandStillNamedWithSlots() {
        let capture = Self.capture(.ft8(), readSeconds: 8, endInTransmission: 7.5, rfHz: 14_200_000, seed: 4)
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
