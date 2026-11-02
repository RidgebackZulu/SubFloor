import Accelerate
import DSPCore
import Foundation
import Testing
@testable import SignalID

/// Tones that take turns are one signal (`SignalGrouper`), measured from those tones (`DirectFSK`).
///
/// The corpus holds one FSK emitter, split by time, so what it says doesn't generalise: these synthetic cases have to
/// carry the other speeds, shifts, fades and neighbours. They are a regression check, not a figure for how it does on
/// the air. `generalisationGrid` is the whole of them, behind `SUBFLOOR_SIGNALID_MATRIX=1`.
@Suite(.serialized) struct DirectFSKTests {
    static let rate = 48_000.0

    /// The signals around `pointHz` as `identify(iq:…)` sees them.
    static func signals(_ iq: [Float], pointHz: Double, radiusHz: Double = 60) -> [SignalCandidate] {
        let hood = SignalIdentifier.neighbourhood(iq, sampleRate: rate, pointHz: pointHz)
        return SignalIdentifier.candidates(hood, view: TraceFinder.find(hood.map), pointHz: pointHz, radiusHz: radiusHz)
    }

    static func describe(_ signals: [SignalCandidate]) -> String {
        signals.map { "\($0.kind) \(Int($0.lowerHz))…\(Int($0.upperHz))" }.joined(separator: "; ")
    }

    static func identified(_ iq: [Float], centerHz: Double, pointHz: Double, rate: Double = rate) -> SignalIdentity {
        SignalIdentifier.identify(iq: iq, sampleRate: rate, captureCenterHz: centerHz, atHz: centerHz + pointHz,
                                  bandwidthHz: nil, spectrumDb: nil, longer: nil)
    }

    /// The noise density `SignalSynth.make` gives `spec` at `snrDb`, in dB relative to 1 per Hz, the signal's power being 1.
    static func noiseDb(_ spec: SynthSpec, snrDb: Double) -> Double {
        -snrDb - 10 * log10(spec.occupiedBandwidthHz)
    }

    static func complex(_ iq: [Float]) -> [DSPComplex] {
        iq.withUnsafeBufferPointer { $0.withMemoryRebound(to: DSPComplex.self) { Array($0) } }
    }

    // MARK: Grouping

    @Test func alternatingTonesAreOneSignal() throws {
        let iq = SignalSynth.make(.rtty(baud: 75, shiftHz: 850), sampleRate: Self.rate, seconds: 3, snrDb: 20,
                                  offsetHz: 2000, seed: 1)
        let found = Self.signals(iq, pointHz: 2000 - 425)
        let fsks = found.filter { $0.tones != nil }
        #expect(found.count == 1 && fsks.count == 1, "\(Self.describe(found))")
        let tones = try #require(fsks.first?.tones)
        #expect(tones.count == 2)
        #expect(abs(tones[0] - 1575) < 30 && abs(tones[1] - 2425) < 30, "\(tones)")
    }

    /// Two carriers `apartHz` apart, each keyed on and off at random, `baud` a second.
    static func keyedPair(baud: Double, apartHz: Double, seed: UInt64) -> [Float] {
        var iq = SignalSynth.make(.noise, sampleRate: rate, seconds: 3, snrDb: 0, seed: seed)
        var random = SynthRandom(seed: seed, stream: 5)
        for offset in [-apartHz / 2, apartHz / 2] {
            let phase = 2 * Double.pi * offset / rate
            let symbol = Int(rate / baud)
            var on = false
            for k in 0..<(iq.count / 2) {
                if k % symbol == 0 { on = random.int(2) == 1 }
                guard on else { continue }
                iq[2 * k] += 0.3 * Float(cos(phase * Double(k)))
                iq[2 * k + 1] += 0.3 * Float(sin(phase * Double(k)))
            }
        }
        return iq
    }

    @Test func independentCarriersStayApart() {
        for (baud, seed) in Sweep.full ? [(75.0, UInt64(2)), (40, 3), (12, 18)] : [(12.0, UInt64(18))] {
            let iq = Self.keyedPair(baud: baud, apartHz: 850, seed: seed)
            let found = Self.signals(iq, pointHz: -425)
            #expect(found.count == 2 && found.allSatisfy { $0.kind == .single }, "\(baud) Bd: \(Self.describe(found))")
            let id = Self.identified(iq, centerHz: 11_000_000, pointHz: -425)
            #expect(id.measurement.fskShiftHz == nil, "\(baud) Bd: \(id.label)")
        }
        // Two stations sending Morse.
        var morse = SignalSynth.make(.cw(wpm: 22), sampleRate: Self.rate, seconds: 3, snrDb: 25, offsetHz: -425, seed: 4)
        let other = SignalSynth.make(.cw(wpm: 22), sampleRate: Self.rate, seconds: 3, snrDb: 25, offsetHz: 425, seed: 5)
        for k in morse.indices { morse[k] += other[k] }
        let found = Self.signals(morse, pointHz: -425)
        #expect(!found.contains { $0.tones != nil }, "\(Self.describe(found))")
    }

    /// Stations that alternate on a slow schedule take turns, but not within a symbol's reach.
    @Test func stationsThatAlternateSlowlyStayApart() {
        var iq = SignalSynth.make(.noise, sampleRate: Self.rate, seconds: 4, snrDb: 0, seed: 6)
        for (offset, phase) in [(-300.0, 0), (400, 1)] {
            let step = 2 * Double.pi * offset / Self.rate
            for k in 0..<(iq.count / 2) where Int(Double(k) / Self.rate) % 2 == phase {
                iq[2 * k] += 0.3 * Float(cos(step * Double(k)))
                iq[2 * k + 1] += 0.3 * Float(sin(step * Double(k)))
            }
        }
        let found = Self.signals(iq, pointHz: -300)
        #expect(!found.contains { $0.tones != nil }, "\(Self.describe(found))")
    }

    @Test func fskWithFadingOnOneTone() throws {
        let spec = SynthSpec.rtty(baud: 75, shiftHz: 850)
        let iq = SignalSynth.make(spec, sampleRate: Self.rate, seconds: 3, snrDb: 20, offsetHz: 1000, seed: 7,
                                  impairments: SignalSynth.fading(toneIndex: 0, depthDb: 10))
        let found = Self.signals(iq, pointHz: 1000 + 425)
        #expect(found.count == 1 && found.first?.tones?.count == 2, "\(Self.describe(found))")
        let id = Self.identified(iq, centerHz: 11_000_000, pointHz: 1000 + 425)
        #expect(id.label.hasPrefix("2-FSK · 75"), "\(id.label)")
    }

    /// Fades on the tone do what they do to the signal: only that tone.
    @Test func aToneFadesAlone() {
        let spec = SynthSpec.rtty(baud: 50, shiftHz: 850)
        let fades = SignalSynth.fading(toneIndex: 0, depthDb: 20, rateHz: 1)
        let faded = SignalSynth.make(spec, sampleRate: Self.rate, seconds: 4, snrDb: .infinity, seed: 8, impairments: fades)
        func power(_ iq: [Float], _ hz: Double) -> [Double] {
            let cut = Channel.extract(iq, sampleRate: Self.rate, offsetHz: hz, bandwidthHz: 200)
            let block = Int(cut.rate / 2)
            return stride(from: 0, to: cut.samples.count - block, by: block).map { start in
                cut.samples[start..<(start + block)].reduce(0.0) { $0 + Double($1.real * $1.real + $1.imag * $1.imag) }
            }
        }
        let low = power(faded, -425), high = power(faded, 425)
        func range(_ x: [Double]) -> Double { 10 * log10(x.max()! / x.min()!) }
        #expect(range(low) >= 8, "\(low)")
        #expect(range(low) >= range(high) + 3, "\(low) \(high)")
    }

    @Test func fskBesideAStrongCarrier() throws {
        var iq = SignalSynth.make(.rtty(baud: 50, shiftHz: 425), sampleRate: Self.rate, seconds: 3, snrDb: 10, offsetHz: 0, seed: 9)
        TraceFinderTests.addCarrier(to: &iq, offsetHz: 212.5 + 2000, amplitude: 10)
        let found = Self.signals(iq, pointHz: 212.5)
        let fsks = found.filter { $0.tones != nil }
        #expect(fsks.count == 1, "\(Self.describe(found))")
        #expect(found.contains { $0.kind == .single && $0.lowerHz > 2000 }, "\(Self.describe(found))")
        let id = Self.identified(iq, centerHz: 11_000_000, pointHz: 212.5)
        let m = id.measurement
        #expect(m.family == .fsk, "\(id.label)")
        #expect(abs((m.fskShiftHz ?? 0) - 425) <= 0.03 * 425, "\(id.label)")
        #expect(abs((m.symbolRate ?? 0) - 50) <= 0.01 * 50, "\(id.label)")
        #expect(m.offsetHz + m.occupiedBandwidthHz / 2 < 2000, "\(id.label) at \(m.offsetHz)")
        // The carrier is still the carrier.
        let carrier = Self.identified(iq, centerHz: 11_000_000, pointHz: 2212.5)
        #expect(carrier.measurement.fskShiftHz == nil, "\(carrier.label)")
    }

    @Test func thePointBetweenTheTonesIsOnTheSignal() {
        let iq = SignalSynth.make(.rtty(baud: 50, shiftHz: 850), sampleRate: Self.rate, seconds: 3, snrDb: 20, seed: 10)
        let id = Self.identified(iq, centerHz: 11_000_000, pointHz: 0)
        #expect(id.label.hasPrefix("2-FSK · 50"), "\(id.label)")
    }

    /// A wide trace with two humps: a narrow shift, strong, whose valley stands well over the noise.
    @Test func aNarrowShiftHeldInOneTraceIsStillTwoTones() {
        let iq = SignalSynth.make(.rtty(baud: 45.45, shiftHz: 170), sampleRate: Self.rate, seconds: 3, snrDb: 30, offsetHz: 500, seed: 11)
        let found = Self.signals(iq, pointHz: 500)
        #expect(found.count == 1 && found.first?.tones?.count == 2, "\(Self.describe(found))")
    }

    // MARK: The reading

    struct RTTYCase: Sendable, CustomTestStringConvertible {
        var baud, shift, snr: Double
        var testDescription: String { "\(baud) Bd, \(shift) Hz, \(snr) dB" }
    }

    static let rttyCases: [RTTYCase] = [(45.45, 170.0), (50, 425), (75, 850), (100, 170)].flatMap { speed, shift in
        [20.0, 10].map { RTTYCase(baud: speed, shift: shift, snr: $0) }
    }

    @Test(arguments: rttyCases) func directReading(c: RTTYCase) throws {
        let spec = SynthSpec.rtty(baud: c.baud, shiftHz: c.shift)
        let rate = 12_000.0
        let iq = SignalSynth.make(spec, sampleRate: rate, seconds: 3, snrDb: c.snr, seed: UInt64(c.baud + c.shift + c.snr))
        // Tones a little off, as a map's bins put them.
        let reading = try #require(DirectFSK.measure(Self.complex(iq), rate: rate, tonesHz: [-c.shift / 2 - 5, c.shift / 2 + 3],
                                                     noiseDb: Self.noiseDb(spec, snrDb: c.snr)))
        #expect(reading.toneCount == 2)
        #expect(abs((reading.shiftHz ?? 0) - c.shift) <= 0.03 * c.shift, "\(reading)")
        #expect(abs((reading.baud ?? 0) - c.baud) <= 0.01 * c.baud, "\(reading)")
        #expect(abs(reading.snrDb - c.snr) <= 3, "\(reading)")
        #expect(reading.baudConfidence >= 0.5, "\(reading)")
    }

    /// Amateur RTTY as it is sent: start-stop, 5 bits with 1.5 stop bits, whose changes lie on a half-symbol grid.
    @Test(arguments: [(45.45, 170.0, 20.0), (45.45, 170, 10), (50, 850, 15)]) func startStopKeying(baud: Double, shift: Double, snr: Double) throws {
        let rate = 12_000.0, seconds = 4.0
        var random = SynthRandom(seed: 12, stream: 7)
        var frequency: [Double] = []
        func hold(_ hz: Double, _ symbols: Double) {
            frequency += [Double](repeating: hz, count: Int((symbols / baud * rate).rounded()))
        }
        while Double(frequency.count) < seconds * rate {
            hold(-shift / 2, 1)
            for _ in 0..<5 { hold(random.int(2) == 1 ? shift / 2 : -shift / 2, 1) }
            hold(shift / 2, 1.5)
        }
        var x = SynthDSP.frequencyModulate(Array(frequency.prefix(Int(seconds * rate))), rate: rate, random: &random)
        x.normalisePower(over: x.count)
        var iq = [Float](repeating: 0, count: 2 * x.count)
        for k in 0..<x.count {
            iq[2 * k] = x.re[k]
            iq[2 * k + 1] = x.im[k]
        }
        let width = shift + 4 * baud
        let density = pow(10, -snr / 10) / width
        var noise = SynthRandom(seed: 12, stream: 8)
        SynthNoise.add(to: &iq, power: density * rate, random: &noise)
        let reading = try #require(DirectFSK.measure(Self.complex(iq), rate: rate, tonesHz: [-shift / 2, shift / 2],
                                                     noiseDb: 10 * log10(density)))
        #expect(abs((reading.baud ?? 0) - baud) <= 0.01 * baud, "\(reading)")
        #expect(abs((reading.shiftHz ?? 0) - shift) <= 0.03 * shift, "\(reading)")
    }

    @Test func fourToneReading() throws {
        let spec = SynthSpec.fsk(.init(tones: 4, rate: 50, spacingHz: 400))
        let rate = 12_000.0
        let iq = SignalSynth.make(spec, sampleRate: rate, seconds: 3, snrDb: 15, seed: 13)
        let reading = try #require(DirectFSK.measure(Self.complex(iq), rate: rate, tonesHz: [-600, -200, 200, 600],
                                                     noiseDb: Self.noiseDb(spec, snrDb: 15)))
        #expect(reading.toneCount == 4 && reading.shiftHz == nil, "\(reading)")
        #expect(abs((reading.spacingHz ?? 0) - 400) <= 12, "\(reading)")
        #expect(abs((reading.baud ?? 0) - 50) <= 0.5, "\(reading)")
    }

    /// FM that wanders between the same frequencies isn't on either of them for long, and keeps no time.
    @Test func voiceOnFMIsNoKeying() {
        let rate = 12_000.0
        let spec = SynthSpec.fm(.voice(lowHz: 300, highHz: 1500), deviationHz: 500)
        let iq = SignalSynth.make(spec, sampleRate: rate, seconds: 3, snrDb: 25, seed: 14)
        let reading = DirectFSK.measure(Self.complex(iq), rate: rate, tonesHz: [-400, 400], noiseDb: Self.noiseDb(spec, snrDb: 25))
        #expect(reading?.baud == nil, "\(String(describing: reading))")
    }

    // MARK: On the real FSK

    /// Its SNR has a real reference: never the 97 dB a filtered channel gave.
    @Test func realSNRIsPlausible() throws {
        let points = try RealCorpus.points(.tuning).filter { $0.truth == "2-FSK" && $0.transmitting }
        let clips = try RealCorpus.clips()
        for point in Sweep.full ? points : Array(points.prefix(2)) {
            let clip = try #require(clips.first { $0.name == point.clip })
            let id = RealCorpus.hover(clip, point)
            #expect((3...50).contains(id.measurement.snrDb), "\(point.atHz) to \(point.endSeconds) s: \(IdentifyTests.describe(id))")
        }
    }

    // MARK: Names

    @Test func ttyOutsideHamBandsStaysFSK() {
        let iq = SignalSynth.make(.rtty(baud: 75, shiftHz: 850), sampleRate: Self.rate, seconds: 3, snrDb: 20, seed: 15)
        let id = Self.identified(iq, centerHz: 11_688_000, pointHz: 425)
        #expect(id.best == nil, "\(IdentifyTests.describe(id))")
        #expect(id.label.hasPrefix("2-FSK · 75"), "\(id.label)")
        // RTTY is what it would be, were it shown to be: offered, not named.
        #expect(id.alternatives.contains { $0.name == "RTTY" && $0.confidence < SignalIdentifier.nameThreshold },
                "\(IdentifyTests.describe(id))")
    }

    @Test func rttyInHamSegmentIsNamed() {
        let iq = SignalSynth.make(.rtty(baud: 45.45, shiftHz: 170), sampleRate: Self.rate, seconds: 3, snrDb: 20, seed: 16)
        let id = Self.identified(iq, centerHz: 14_085_000, pointHz: 0)
        #expect(id.best?.name == "RTTY", "\(IdentifyTests.describe(id))")
    }

    /// A readable decode stands in for the frequencies (Task 8 supplies it).
    @Test func aReadableDecodeNamesRTTYAnywhere() {
        let m = SignalMeasurement(occupiedBandwidthHz: 1300, snrDb: 20, envelope: .steady, family: .fsk, familyConfidence: 1,
                                  symbolRate: 75, fskShiftHz: 850, toneCount: 2, toneSpacingHz: 850, seconds: 3)
        #expect(SignalIdentifier.identify(m, rfHz: 11_688_000).best == nil)
        #expect(SignalIdentifier.identify(m, rfHz: 11_688_000, readableDecode: true).best?.name == "RTTY")
    }

    /// CW with hard edges: clicks either side of the carrier, which run with it, not against it.
    @Test func cornerCaseCWIsNotFSK() {
        var iq = SignalSynth.make(.noise, sampleRate: Self.rate, seconds: 3, snrDb: 0, seed: 17)
        let unit = Int(0.06 * Self.rate)
        var random = SynthRandom(seed: 17, stream: 6)
        var key: [Bool] = []
        while key.count < iq.count / 2 {
            key += [Bool](repeating: true, count: unit * (random.int(2) == 1 ? 3 : 1))
            key += [Bool](repeating: false, count: unit * (random.int(3) == 0 ? 3 : 1))
        }
        let step = 2 * Double.pi * 800 / Self.rate
        for k in 0..<(iq.count / 2) where key[k] {
            iq[2 * k] += 0.2 * Float(cos(step * Double(k)))
            iq[2 * k + 1] += 0.2 * Float(sin(step * Double(k)))
        }
        let id = Self.identified(iq, centerHz: 14_030_000, pointHz: 800)
        #expect(id.measurement.family == .ook, "\(IdentifyTests.describe(id))")
        #expect(id.best?.name == "CW", "\(IdentifyTests.describe(id))")
        #expect(id.measurement.fskShiftHz == nil, "\(IdentifyTests.describe(id))")
    }

    // MARK: How far it generalises

    enum Neighbour: CaseIterable, CustomStringConvertible {
        case none, carrierAbove, fskBelow
        var description: String {
            switch self {
            case .none: "alone"
            case .carrierAbove: "a carrier +20 dB 1.5 kHz above"
            case .fskBelow: "another FSK 2.5 kHz below"
            }
        }
    }

    /// `id` is the FSK at the point: its shift and speed right, a narrow signal not taken for its neighbour.
    static func isRight(_ id: SignalIdentity, baud: Double, shift: Double) -> Bool {
        let m = id.measurement
        guard m.family == .fsk, m.toneCount == 2, let s = m.fskShiftHz, let r = m.symbolRate else { return false }
        return abs(s - shift) <= 0.03 * shift && abs(r - baud) <= 0.01 * baud
    }

    /// One capture of the grid: the FSK centred on 0, pointed at its upper tone.
    static func capture(baud: Double, shift: Double, snr: Double, fade: Double, neighbour: Neighbour, seed: UInt64) -> [Float] {
        var iq = SignalSynth.make(.rtty(baud: baud, shiftHz: shift), sampleRate: rate, seconds: 3, snrDb: snr, seed: seed,
                                  impairments: fade > 0 ? SignalSynth.fading(toneIndex: 0, depthDb: fade) : .none)
        switch neighbour {
        case .none: break
        case .carrierAbove: TraceFinderTests.addCarrier(to: &iq, offsetHz: shift / 2 + 1500, amplitude: 10)
        case .fskBelow:
            let other = SignalSynth.render(.rtty(baud: 50, shiftHz: 200), sampleRate: rate, seconds: 3,
                                           offsetHz: -shift / 2 - 2500, seed: seed + 100)
            for k in iq.indices { iq[k] += other[k] }
        }
        return iq
    }

    /// Every speed, shift, level, fade and neighbour through the whole identification. A default run has `oneCaseOfEach`.
    @Test(.enabled(if: Sweep.full)) func generalisationGrid() {
        var tally: [String: (right: Int, total: Int)] = [:]
        var wrong: [String] = []
        for shift in [170.0, 200, 425, 450, 600, 850, 1000, 1400] {
            for baud in [45.45, 50, 56.25, 75, 100, 150] where shift / baud >= 1.5 {
                for snr in [20.0, 12] {
                    for fade in [0.0, 10] {
                        for neighbour in Neighbour.allCases {
                            for seed in 1...UInt64(2) {
                                let iq = Self.capture(baud: baud, shift: shift, snr: snr, fade: fade, neighbour: neighbour,
                                                      seed: seed * 1000 + UInt64(baud) + UInt64(shift))
                                let id = Self.identified(iq, centerHz: 11_000_000, pointHz: shift / 2)
                                let right = Self.isRight(id, baud: baud, shift: shift)
                                for key in ["all", "\(snr) dB", "\(baud) Bd", "\(shift) Hz", "fade \(fade)", "\(neighbour)"] {
                                    tally[key, default: (0, 0)].total += 1
                                    if right { tally[key, default: (0, 0)].right += 1 }
                                }
                                if !right, wrong.count < 40 {
                                    wrong.append("\(baud)/\(shift) \(snr) dB fade \(fade) \(neighbour): \(id.label)")
                                }
                            }
                        }
                    }
                }
            }
        }
        for key in tally.keys.sorted() {
            print("generalisationGrid \(key): \(tally[key]!.right)/\(tally[key]!.total)")
        }
        for line in wrong { print("generalisationGrid wrong: \(line)") }
        let all = tally["all"] ?? (0, 1)
        #expect(Double(all.right) >= 0.9 * Double(all.total), "\(all)")
    }

    @Test func oneCaseOfEach() {
        // The rest of each kind: `fskBesideAStrongCarrier`, `fskWithFadingOnOneTone`, `rttyInHamSegmentIsNamed`.
        for (baud, shift, snr, fade, neighbour) in [(100.0, 450.0, 12.0, 10.0, Neighbour.none), (50, 1000, 20, 10, .fskBelow)] {
            let iq = Self.capture(baud: baud, shift: shift, snr: snr, fade: fade, neighbour: neighbour, seed: 21)
            let id = Self.identified(iq, centerHz: 11_000_000, pointHz: shift / 2)
            #expect(Self.isRight(id, baud: baud, shift: shift), "\(baud)/\(shift) \(snr) dB fade \(fade) \(neighbour): \(IdentifyTests.describe(id))")
        }
    }
}
