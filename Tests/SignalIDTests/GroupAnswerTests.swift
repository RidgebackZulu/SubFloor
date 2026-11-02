import Foundation
import Testing
@testable import SignalID

/// Several signals under the point (`SignalIdentifier.underThePoint`): one answer describes them all, and one signal's
/// answer is as it was.
@Suite(.serialized) struct GroupAnswerTests {
    static let rate = 6000.0
    /// The capture's centre: the groups sit in 20 m's FT8 frequencies around it.
    static let centreHz = 14_075_500.0
    static let seconds = 3.0

    /// An FT8 at `offsetHz`, `snrDb`. The read is its slot's first 3 s: the transmission starts in it, 0.5 s in, and
    /// `lateSeconds` later than that (stations' clocks differ).
    static func ft8(_ offsetHz: Double, snrDb: Double, seed: UInt64, lateSeconds: Double = 0) -> SignalSynth.Placed {
        guard case .bursts(let inner, var bursts) = SynthSpec.ft8() else { fatalError("FT8 is bursts") }
        bursts.captureStartSeconds = bursts.periodSeconds - lateSeconds
        return SignalSynth.Placed(.bursts(inner, bursts), offsetHz: offsetHz, snrDb: snrDb, seed: seed)
    }

    /// 9 FT8 stations 300 Hz apart (−1200 … +1200 Hz), at 6 to 14 dB, every other one 0.2 s late (two schedules: each
    /// new one costs the synthesiser a long render for its width), and one more 900 Hz past the group's top edge: too far
    /// to be of its group.
    static let nineSNRs: [Double] = [8, 12, 6, 14, 10, 9, 13, 7, 11]
    static let nineLate: [Double] = [0, 0.2, 0, 0.2, 0, 0.2, 0, 0.2, 0]
    static let nineSpecs: [SignalSynth.Placed] = (0..<9).map { (k: Int) -> SignalSynth.Placed in
        ft8(Double(k - 4) * 300, snrDb: nineSNRs[k], seed: UInt64(10 + k), lateSeconds: nineLate[k])
    } + [ft8(2150, snrDb: 12, seed: 30)]
    static let nine = SignalSynth.several(nineSpecs, sampleRate: rate, seconds: seconds, noiseSeed: 1)
    /// The group from its middle, at a radius wider than the stations' spacing: made once, for the tests that look at it.
    static let nineWide = identify(nine, atOffset: 0, radiusHz: 700)

    /// The hover's refining call (the read already in hand, so its longer read is this read).
    static func identify(_ iq: [Float], atOffset: Double, radiusHz: Double, rate: Double = rate,
                         centreHz: Double = centreHz, captureSpectrumDb: [Float]? = nil) -> SignalIdentity {
        let seconds = Double(iq.count / 2) / rate
        return SignalIdentifier.identify(iq: iq, sampleRate: rate, captureCenterHz: centreHz, atHz: centreHz + atOffset,
                                         bandwidthHz: nil, spectrumDb: nil, longer: { (iq, seconds) },
                                         pointRadiusHz: radiusHz, captureSpectrumDb: captureSpectrumDb,
                                         captureRate: captureSpectrumDb == nil ? nil : rate)
    }

    static func describe(_ id: SignalIdentity) -> String {
        "\(id.label) [" + id.signals.map { "\(Int($0.measurement.offsetHz.rounded())): \($0.label)" }.joined(separator: "; ") + "]"
    }

    /// Whether `id` was measured, not taken from another (`SignalIdentifier.unmeasured`).
    static func wasMeasured(_ id: SignalIdentity) -> Bool { !id.measurement.notes.contains { $0.hasPrefix("Not measured") } }

    /// 9 FT8 stations 300 Hz apart, the point in their middle at a radius of 700 Hz: the answer is the whole group, its
    /// span wider than the radius, and not the station 900 Hz past its edge. Three are measured: the point's own and the
    /// two strongest; the rest take FT8 from them.
    @Test func wideRadiusOnAGroupDescribesIt() throws {
        let id = Self.nineWide
        #expect(id.label == "FT8 · 9 signals · 14.0743–14.0767 MHz", "\(Self.describe(id))")
        #expect(id.signals.count == 9, "\(Self.describe(id))")
        let span = try #require(id.groupSpanHz)
        #expect(abs(span.lowerBound + 1225) < 30 && abs(span.upperBound - 1225) < 30, "\(span)")
        #expect(id.best?.name == "FT8" && id.signals.allSatisfy { $0.signals.isEmpty })
        let measured = id.signals.filter(Self.wasMeasured).map(\.measurement.offsetHz).sorted()
        #expect(measured.count == SignalIdentifier.firstPassMeasured, "\(measured)")
        // The point's own (0 Hz) and the strongest two within the radius (14 dB at −300 Hz, 13 dB at +600 Hz).
        for (got, want) in zip(measured, [-300.0, 0, 600]) { #expect(abs(got - want) < 15, "\(measured)") }
        #expect(id.signals.filter { !Self.wasMeasured($0) }.allSatisfy {
            $0.best?.evidence.contains { $0.hasPrefix("the same slot and width as the FT8") } == true
        })
    }

    /// The same group at a radius of 30 Hz on a station: one signal, its answer as ever.
    @Test func narrowRadiusNamesOne() {
        let id = Self.identify(Self.nine, atOffset: 0, radiusHz: 30)
        #expect(id.signals.isEmpty && id.groupSpanHz == nil, "\(Self.describe(id))")
        #expect(id.best?.name == "FT8", "\(IdentifyTests.describe(id))")
    }

    /// 3 FT8 stations and a CW key under the point, and a fourth FT8 past the radius: a mixed answer, counted, the CW
    /// measured. The names aren't one slot mode's, so the answer stays within the radius.
    static let mixed: SignalIdentity = {
        let cw = SignalSynth.Placed(.cw(wpm: 20), offsetHz: 150, snrDb: 20, seed: 41)
        let iq = SignalSynth.several([ft8(-450, snrDb: 12, seed: 42), ft8(-150, snrDb: 10, seed: 43),
                                      ft8(450, snrDb: 9, seed: 44, lateSeconds: 0.2), cw, ft8(-850, snrDb: 12, seed: 45)],
                                     sampleRate: rate, seconds: seconds, noiseSeed: 2)
        return identify(iq, atOffset: 100, radiusHz: 700)
    }()

    @Test func mixedSignalsAreCounted() {
        let id = Self.mixed
        #expect(id.label == "Several signals: FT8 ×3, CW ×1", "\(Self.describe(id))")
        #expect(id.groupSpanHz == nil && id.signals.count == 4, "\(Self.describe(id))")
    }

    /// A signal alone under a wide radius is one signal: an RTTY's two tones are one FSK (`SignalGrouper`), and its answer
    /// is the one a narrow radius gives.
    @Test func oneSignalIsUnchanged() {
        let iq = SignalSynth.make(.rtty(), sampleRate: Self.rate, seconds: Self.seconds, snrDb: 15, offsetHz: 0, seed: 51)
        func at(_ radiusHz: Double) -> SignalIdentity {
            SignalIdentifier.identify(iq: iq, sampleRate: Self.rate, captureCenterHz: 14_085_000, atHz: 14_085_000,
                                      bandwidthHz: nil, spectrumDb: nil, longer: nil, pointRadiusHz: radiusHz)
        }
        let narrow = at(60), wide = at(345)
        #expect(narrow.signals.isEmpty && wide.signals.isEmpty, "\(Self.describe(wide))")
        #expect(wide.label == narrow.label && narrow.best?.name == "RTTY", "\(wide.label) vs \(narrow.label)")
        // One signal's JSON is as it was: no group fields.
        let json = String(decoding: (try? JSONEncoder().encode(wide)) ?? Data(), as: UTF8.self)
        #expect(!json.contains("signals") && !json.contains("groupSpanHz") && !json.contains("captureCenterHz"), "\(json)")
    }

    /// A carrier's sidebands lie inside its answer: an AM carrier with its two tone lines is one signal at any radius.
    @Test func aSignalsOwnLinesAreNotOthers() {
        let iq = SignalSynth.make(.am(.tone(400), depth: 0.7), sampleRate: Self.rate, seconds: Self.seconds, snrDb: 25,
                                  offsetHz: 0, seed: 61)
        let id = SignalIdentifier.identify(iq: iq, sampleRate: Self.rate, captureCenterHz: 10_000_000, atHz: 10_000_000,
                                           bandwidthHz: nil, spectrumDb: nil, longer: nil, pointRadiusHz: 700)
        #expect(id.signals.isEmpty, "\(Self.describe(id))")
    }

    /// A point inside an area (USB voice, ±1.2 kHz) is that signal's, whatever lines lie beside it within the radius.
    @Test func aPointInAnAreaIsThatSignal() {
        let iq = SignalSynth.several([
            SignalSynth.Placed(.ssb(upper: true, lowHz: 300, highHz: 2700), offsetHz: 0, snrDb: 20, seed: 81),
            SignalSynth.Placed(.cw(wpm: 20), offsetHz: -1650, snrDb: 20, seed: 82),
            SignalSynth.Placed(.cw(wpm: 25), offsetHz: 1650, snrDb: 20, seed: 83),
        ], sampleRate: Self.rate, seconds: Self.seconds, noiseSeed: 84)
        let id = SignalIdentifier.identify(iq: iq, sampleRate: Self.rate, captureCenterHz: 7_150_000, atHz: 7_150_000,
                                           bandwidthHz: nil, spectrumDb: nil, longer: nil, pointRadiusHz: 1700)
        #expect(id.signals.isEmpty && id.best?.name == "SSB voice (USB/LSB)", "\(Self.describe(id))")
    }

    /// A mode that isn't a slot mode is no group, and lends no name: five PSK31 stations 300 Hz apart, four within the
    /// radius (three of them measured), the fifth past it within the group's reach. They all start 0.35 s into the read, so
    /// their timing agrees as a slot mode's would.
    @Test func onlyASlotModeIsAGroup() {
        let started = SynthSpec.bursts(.psk31, .init(periodSeconds: 15, onSeconds: 10, startSeconds: 0.35, rampSeconds: 0.02))
        let psk = (0..<5).map { k in
            SignalSynth.Placed(started, offsetHz: [-450, -150, 150, 450, 800][k], snrDb: [15, 18, 16, 12, 15][k],
                               seed: UInt64(90 + k))
        }
        let iq = SignalSynth.several(psk, sampleRate: Self.rate, seconds: Self.seconds, noiseSeed: 95)
        let id = SignalIdentifier.identify(iq: iq, sampleRate: Self.rate, captureCenterHz: 14_071_000, atHz: 14_071_000,
                                           bandwidthHz: nil, spectrumDb: nil, longer: nil, pointRadiusHz: 600)
        #expect(id.signals.count == 4 && id.groupSpanHz == nil, "\(Self.describe(id))")
        #expect(id.label == "Several signals: PSK31 / PSK63 ×3, unknown ×1", "\(Self.describe(id))")
    }

    /// The label for several: a group's form only when every signal reads as its mode, counts otherwise; a span under
    /// 1 MHz in kHz.
    @Test func theLabelCountsEverySignal() {
        func one(_ name: String?) -> SignalIdentity {
            SignalIdentity(measurement: SignalMeasurement(occupiedBandwidthHz: 50, family: .fsk),
                           best: name.map { ModeMatch(name: $0, confidence: 0.9, evidence: []) })
        }
        var id = one("FT8")
        id.signals = [one("FT8"), one("FT8")]
        id.groupSpanHz = -100...400
        id.captureCenterHz = 474_000
        #expect(id.label == "FT8 · 2 signals · 473.9–474.4 kHz", "\(id.label)")
        id.signals.append(one(nil))
        #expect(id.label == "Several signals: FT8 ×2, unknown ×1", "\(id.label)")
        // The named first, however many the unknown are.
        id.signals += [one(nil), one(nil), one("CW")]
        #expect(id.label == "Several signals: FT8 ×2, CW ×1, unknown ×3", "\(id.label)")
        // Its JSON keeps the group, and reads back.
        let back = try? JSONDecoder().decode(SignalIdentity.self, from: JSONEncoder().encode(id))
        #expect(back == id)
    }

    /// Narrow signals on for the whole read beside FT8 stations caught inside their transmissions share no timing with them:
    /// a PSK31 and a PSK63 are never given FT8's (or FT4's) name, with or without a true time (the review's probe).
    @Test func continuousSignalsBesideAGroupInheritNothing() {
        guard case .bursts(let inner, var bursts) = SynthSpec.ft8() else { return }
        bursts.captureStartSeconds = 3
        let ft8 = SynthSpec.bursts(inner, bursts)
        let iq = SignalSynth.several([
            SignalSynth.Placed(ft8, offsetHz: -300, snrDb: 13, seed: 101), SignalSynth.Placed(ft8, offsetHz: 0, snrDb: 12, seed: 102),
            SignalSynth.Placed(ft8, offsetHz: 300, snrDb: 14, seed: 103),
            SignalSynth.Placed(.psk31, offsetHz: 600, snrDb: 8, seed: 104), SignalSynth.Placed(.psk63, offsetHz: -600, snrDb: 8, seed: 105),
        ], sampleRate: Self.rate, seconds: Self.seconds, noiseSeed: 106)
        // With a true time too, with the matrix (`onlyTheSameSlotAndWidthInherit` holds that rule by default).
        for end in [nil] + (Sweep.full ? [SignalSynth.endTime(ft8, seconds: Self.seconds)] : []) {
            let id = SignalIdentifier.identify(iq: iq, sampleRate: Self.rate, captureCenterHz: Self.centreHz,
                                               atHz: Self.centreHz, bandwidthHz: nil, spectrumDb: nil,
                                               longer: { (iq, Self.seconds) }, pointRadiusHz: 700, endTime: end)
            #expect(id.signals.count >= 4, "\(Self.describe(id))")
            let psks = id.signals.filter { abs(abs($0.measurement.offsetHz) - 600) < 60 }
            #expect(psks.count == 2 && psks.allSatisfy { !["FT8", "FT4"].contains($0.best?.name ?? "") },
                    "\(end == nil ? "no time" : "true time"): \(Self.describe(id))")
        }
    }

    /// A cancelled task's answer from several signals is `cancelledNote`, as everywhere else.
    @Test func cancelledWhileMeasuringOthers() async {
        let iq = Self.nine
        let id = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let hood = SignalIdentifier.neighbourhood(iq, sampleRate: Self.rate, pointHz: 0)
            let view = TraceFinder.find(hood.map)
            let signals = SignalIdentifier.candidates(hood, view: view, pointHz: 0, radiusHz: 700)
            let point = SignalIdentity(measurement: SignalMeasurement(offsetHz: 0, occupiedBandwidthHz: 50, family: .fsk))
            return SignalIdentifier.underThePoint(point, first: iq, sampleRate: Self.rate, captureCenterHz: Self.centreHz,
                                                  hood: hood, view: view, signals: signals, pointHz: 0, radiusHz: 700,
                                                  seconds: Self.seconds, endTime: nil, readsTones: true, combLinesHz: [])
        }.value
        #expect(id.note == SignalIdentifier.cancelledNote, "\(Self.describe(id))")
    }

    /// The group's answer on a 3 s read (its longer read that same read) in a release build: ≤ 300 ms, the best of three
    /// after one to warm.
    @Test(.enabled(if: AnalogFamilyTests.optimised())) func wideRadiusStaysFast() {
        let clock = ContinuousClock()
        var id = SignalIdentity(measurement: SignalMeasurement())
        _ = Self.identify(Self.nine, atOffset: 0, radiusHz: 700)
        let elapsed = (0..<3).map { _ in clock.measure { id = Self.identify(Self.nine, atOffset: 0, radiusHz: 700) } }.min()!
        print("wideRadiusStaysFast: \(elapsed)")
        #expect(id.signals.count == 9, "\(Self.describe(id))")
        #expect(elapsed <= .milliseconds(300), "the group's answer took \(elapsed)")
    }

    /// No signal of a group is given a width it doesn't have.
    @Test func noPointlessWidthsInAGroup() {
        for id in [Self.nineWide, Self.mixed] {
            #expect(!id.signals.isEmpty)
            for signal in id.signals {
                #expect(signal.measurement.occupiedBandwidthHz <= RealCorpusTests.widestEmptyAnswerHz, "\(signal.label)")
                #expect(signal.measurement.occupiedBandwidthHz < 300, "\(signal.label)")
            }
        }
    }

    /// An interference comb's lines under the point are no signals: from one of its lines, two FT8 stations beside it are
    /// the answer, the nearer one's the rest of it; the lines alone are the comb's.
    @Test func combLinesAreNotSignals() throws {
        let rate = InterferenceCombTests.rate
        var iq = InterferenceCombTests.capture(seconds: Self.seconds, seed: 71)
        let spectrum = InterferenceCombTests.spectrum(iq)
        let stations = SignalSynth.several([Self.ft8(300, snrDb: 12, seed: 72), Self.ft8(600, snrDb: 10, seed: 73)],
                                           sampleRate: rate, seconds: Self.seconds, noiseSeed: 74)
        let lines = iq
        for k in iq.indices { iq[k] += stations[k] }
        // The comb's lines at ±3 kHz, the stations at +300 and +600 Hz: a radius from the upper line that holds them.
        let lineHz = InterferenceCombTests.lineHz(5)
        #expect(abs(lineHz - 3000) < 1)
        let id = Self.identify(iq, atOffset: lineHz, radiusHz: 2_800, rate: rate, captureSpectrumDb: spectrum)
        #expect(id.label.hasPrefix("FT8 · 2 signals · "), "\(Self.describe(id))")
        #expect(id.comb == nil && id.best?.name == "FT8" && abs(id.measurement.offsetHz - 600) < 15, "\(Self.describe(id))")
        let alone = Self.identify(lines, atOffset: lineHz, radiusHz: 2_800, rate: rate, captureSpectrumDb: spectrum)
        #expect(alone.signals.isEmpty && alone.comb != nil, "\(Self.describe(alone))")
        // From the lower line (−3 kHz), only the station at +300 Hz is in reach as well: its answer, alone.
        let one = Self.identify(iq, atOffset: InterferenceCombTests.lineHz(4), radiusHz: 3_400, rate: rate,
                                captureSpectrumDb: spectrum)
        #expect(one.signals.isEmpty && one.comb == nil && one.best?.name == "FT8" && abs(one.measurement.offsetHz - 300) < 15,
                "\(Self.describe(one))")
    }
}

/// `SignalIdentifier.fitsSameSlot`: what lets an unmeasured trace take a measured one's slot mode.
extension GroupAnswerTests {
    static func line(_ lowerHz: Double, width: Double, on: [ClosedRange<Double>]) -> SignalCandidate {
        let trace = SignalTrace(lowerHz: lowerHz, upperHz: lowerHz + width, snrDb: 10, onTimes: on, steady: false)
        return SignalCandidate(kind: .single, lowerHz: trace.lowerHz, upperHz: trace.upperHz, traces: [trace])
    }

    /// Each rule alone turns away the trace it is for: a key's starts and stops of its own, FT4's width, a start further
    /// off than clocks are, and with a true time a transmission that doesn't fit the slots.
    @Test func onlyTheSameSlotAndWidthInherit() {
        let ft8 = ModeTable.row("FT8")!
        let model = Self.line(0, width: 56, on: [0.6...3.0])
        func fits(_ c: SignalCandidate, as m: SignalCandidate = model, readSeconds: Double = 3, end: Date? = nil) -> Bool {
            SignalIdentifier.fitsSameSlot(c, as: m, readSeconds: readSeconds, endTime: end, row: ft8)
        }
        #expect(fits(Self.line(300, width: 64, on: [0.9...3.0])))
        #expect(fits(Self.line(300, width: 48, on: [2.5...3.0])))
        #expect(!fits(Self.line(300, width: 56, on: [0.6...1.2, 1.6...2.1, 2.5...3.0])), "a key")
        #expect(!fits(Self.line(300, width: 84, on: [0.6...3.0])), "FT4's width")
        #expect(!fits(Self.line(300, width: 56, on: [2.7...3.0])), "too late")
        #expect(!fits(Self.line(300, width: 56, on: [])), "never on")
        #expect(!fits(Self.line(300, width: 56, on: []), as: Self.line(0, width: 56, on: [])), "no timing either side")
        // Both on for the whole read (inside their slot, or a PSK beside an FT8): no edge to agree on, no name.
        #expect(!fits(Self.line(300, width: 56, on: [0...3]), as: Self.line(0, width: 56, on: [0...3])), "no edges")
        // A carrier keyed on with an FT8's start: too narrow.
        #expect(!fits(Self.line(300, width: 24, on: [0.6...3.0])), "a carrier's width")
        // With a true time, one start on the grid fits; one 3.5 s off it, beyond any clock, doesn't, though it agrees with
        // the model's own start within the clocks' 2 s.
        #expect(fits(Self.line(300, width: 64, on: [0.9...3.0]), end: Date(timeIntervalSince1970: SignalSynth.slotEpoch + 3)))
        let early = Self.line(0, width: 56, on: [2.0...15.0]), offGrid = Self.line(300, width: 56, on: [4.0...15.0])
        let boundary = Date(timeIntervalSince1970: SignalSynth.slotEpoch + 15)
        #expect(fits(offGrid, as: early, readSeconds: 15))
        #expect(!fits(offGrid, as: early, readSeconds: 15, end: boundary), "3.5 s off the grid")
        var tones = Self.line(300, width: 56, on: [0.6...3.0])
        tones.kind = .fsk(tones: [300, 356])
        #expect(!fits(tones), "an FSK's tones")
        // 6.5 s long, ending 1.5 s from the model's end: its edges agree, but FT8's slots hold 12.64 s transmissions.
        let long = Self.line(0, width: 56, on: [0.6...6.5]), short = Self.line(300, width: 56, on: [2.4...8.0])
        let end = Date(timeIntervalSince1970: SignalSynth.slotEpoch + 15)
        #expect(fits(short, as: long, readSeconds: 15))
        #expect(!fits(short, as: long, readSeconds: 15, end: end), "off the slots")
    }
}
