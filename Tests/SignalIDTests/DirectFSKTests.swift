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

    /// A keyed pair whose kind `kind` picks: slow keys, and Morse, all of which can look like turns in a segment.
    static func independentPair(kind: Int, apartHz: Double, seed: UInt64) -> [Float] {
        func morse(_ a: Double, _ b: Double) -> [Float] {
            var iq = SignalSynth.make(.cw(wpm: a), sampleRate: rate, seconds: 3, snrDb: 25, offsetHz: -apartHz / 2, seed: seed)
            let other = SignalSynth.make(.cw(wpm: b), sampleRate: rate, seconds: 3, snrDb: 25, offsetHz: apartHz / 2, seed: seed + 500)
            for k in iq.indices { iq[k] += other[k] }
            return iq
        }
        switch kind {
        case 0: return keyedPair(baud: 8, apartHz: apartHz, seed: seed)
        case 1: return keyedPair(baud: 12, apartHz: apartHz, seed: seed)
        case 2: return morse(12, 12)
        default: return morse(25, 8)
        }
    }

    /// The turns picture of `iq` around `pointHz`, as `candidates` makes it.
    static func turnsMap(_ iq: [Float], pointHz: Double, rate: Double = rate) -> TimeFrequencyMap {
        let hood = SignalIdentifier.neighbourhood(iq, sampleRate: rate, pointHz: pointHz)
        let reach = 60 + SignalGrouper.maxShiftHz + SignalIdentifier.turnsRoomHz
        let cut = Channel.extract(SignalMeasurer.interleaved(hood.samples), sampleRate: hood.rate, offsetHz: pointHz - hood.centreHz,
                                  bandwidthHz: 2 * reach, sharp: false)
        return SignalGrouper.turnsMap(cut.samples, rate: cut.rate, centerOffsetHz: pointHz, halfSpanHz: reach)
    }

    static func series(_ map: TimeFrequencyMap, _ hz: Double) -> SignalGrouper.Series { .init(bin: map.bin(hz), map: map) }

    /// Keying whose sinc lobes stand as humps as tall as the tones, close to them and to each other. A lobe follows its
    /// tone, so it takes turns with the other tone too, but it is no tone, and no pair of lobes is another FSK.
    /// (200 Bd, 850 Hz, 30 dB on seed 51 repeats seed 52's case: `SUBFLOOR_SIGNALID_MATRIX=1` only.)
    @Test(arguments: [(100.0, 200.0, 20.0, UInt64(51)), (200, 850, 20, 51), (200, 850, 30, 52), (150, 850, 45, 51),
                      (300, 850, 45, 51), (300, 1200, 30, 51), (45.45, 170, 40, 51)] + (Sweep.full ? [(200, 850, 30, 51)] : []))
    func lobesAreNotTones(baud: Double, shift: Double, snr: Double, seed: UInt64) {
        let iq = SignalSynth.make(.rtty(baud: baud, shiftHz: shift), sampleRate: Self.rate, seconds: 3, snrDb: snr, seed: seed)
        let found = Self.signals(iq, pointHz: shift / 2)
        let fsks = found.filter { $0.tones != nil }
        #expect(fsks.count == 1 && fsks.first?.tones?.count == 2, "\(baud)/\(shift) \(snr) dB: \(Self.describe(found))")
        // Symbols shorter than the picture's frames can leave it choosing a lobe: the reading won't have that (the tones it
        // corrects them to come out too far off), and what measures them next is what answers.
        if baud <= 100 {
            let tones = fsks.first?.tones ?? []
            #expect(tones.count == 2 && abs(tones[0] + shift / 2) <= 40 && abs(tones[1] - shift / 2) <= 40, "\(baud)/\(shift) \(snr) dB: \(tones)")
        }
        // The whole answer takes a measurement as well where the tones don't read, which is heavy.
        guard Sweep.full || (baud == 200 && snr == 30 && seed == 52) else { return }
        let id = Self.identified(iq, centerHz: 11_000_000, pointHz: shift / 2)
        #expect(Self.isRight(id, baud: baud, shift: shift), "\(baud)/\(shift) \(snr) dB: \(IdentifyTests.describe(id))")
    }

    /// Keys that ignore each other, on seeds whose keys happen to run against each other within a segment: only the
    /// correlation over the whole read tells them from tones.
    @Test(arguments: [(0, 850.0, UInt64(2021)), (0, 300, 2047), (2, 850, 2038)]) func independentKeysThatLookLikeTurns(kind: Int, apart: Double, seed: UInt64) throws {
        let iq = Self.independentPair(kind: kind, apartHz: apart, seed: seed)
        let map = Self.turnsMap(iq, pointHz: -apart / 2)
        let x = Self.series(map, -apart / 2), y = Self.series(map, apart / 2)
        let median = try #require(x.medianCorrelation(with: y))
        // What makes this seed worth having: it gets past the median.
        #expect(median <= SignalGrouper.turnsCorrelation, "\(median)")
        #expect(x.overallCorrelation(with: y) > SignalGrouper.overallCorrelation)
        // Past −0.2, the two tests would no longer hold this seed apart.
        #expect(x.overallCorrelation(with: y) <= -0.2 || median > -0.2)
        let found = Self.signals(iq, pointHz: -apart / 2)
        #expect(!found.contains { $0.tones != nil }, "\(Self.describe(found))")
    }

    /// The sweep behind the thresholds, held in the repo: no independent pair joins, over the whole read.
    @Test(.enabled(if: Sweep.full)) func independentPairsNeverJoin() {
        var lowest: Float = 1, pastMedian = 0, pairs = 0
        for seed in 2000...UInt64(2040) {
            for apart in [300.0, 850, 1400] {
                for kind in 0..<4 {
                    let iq = Self.independentPair(kind: kind, apartHz: apart, seed: seed)
                    let found = Self.signals(iq, pointHz: -apart / 2)
                    #expect(!found.contains { $0.tones != nil }, "kind \(kind), \(apart) Hz, seed \(seed): \(Self.describe(found))")
                    let map = Self.turnsMap(iq, pointHz: -apart / 2)
                    let x = Self.series(map, -apart / 2), y = Self.series(map, apart / 2)
                    lowest = min(lowest, x.overallCorrelation(with: y))
                    if let median = x.medianCorrelation(with: y), median <= SignalGrouper.turnsCorrelation { pastMedian += 1 }
                    pairs += 1
                }
            }
        }
        print("independentPairsNeverJoin: \(pairs) pairs, \(pastMedian) past the median, lowest overall \(lowest)")
        #expect(lowest > SignalGrouper.overallCorrelation)
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

    /// Steady carriers beat if they're close, and their beat can't pass for turns (`SignalGrouper`'s notes).
    @Test func steadyCarriersNeverJoin() {
        for apart in Sweep.full ? Array(stride(from: 120.0, through: 420, by: 3.3)) : [150, 300] {
            var iq = SignalSynth.make(.noise, sampleRate: Self.rate, seconds: 3, snrDb: 0, seed: 301)
            TraceFinderTests.addCarrier(to: &iq, offsetHz: 1000, amplitude: 1)
            TraceFinderTests.addCarrier(to: &iq, offsetHz: 1000 + apart, amplitude: 0.8, phase: 1)
            let hood = SignalIdentifier.neighbourhood(iq, sampleRate: Self.rate, pointHz: 1000)
            let view = TraceFinder.find(hood.map)
            let map = Self.turnsMap(iq, pointHz: 1000)
            let found = SignalGrouper.group(view, map: map, lines: hood.map)
            #expect(!found.contains { $0.tones != nil }, "\(apart) Hz: \(Self.describe(found))")
        }
    }

    /// Stations that alternate on a slow schedule, each on through a moment of the other's turn. Over the read they run
    /// against each other as hard as tones do, so it takes the moment-by-moment test to part them.
    @Test func stationsThatAlternateSlowlyStayApart() throws {
        var iq = SignalSynth.make(.noise, sampleRate: Self.rate, seconds: 4, snrDb: 0, seed: 6)
        for (offset, first) in [(-300.0, true), (400, false)] {
            let step = 2 * Double.pi * offset / Self.rate
            for k in 0..<(iq.count / 2) {
                let cycle = (Double(k) / Self.rate).truncatingRemainder(dividingBy: 2)
                guard first ? cycle < 1 + Self.alternationOverlap : (cycle >= 1 || cycle < Self.alternationOverlap) else { continue }
                iq[2 * k] += Float(cos(step * Double(k)))
                iq[2 * k + 1] += Float(sin(step * Double(k)))
            }
        }
        let map = Self.turnsMap(iq, pointHz: -300)
        let x = Self.series(map, -300), y = Self.series(map, 400)
        #expect(x.overallCorrelation(with: y) <= SignalGrouper.overallCorrelation, "\(x.overallCorrelation(with: y))")
        let median = try #require(x.medianCorrelation(with: y))
        #expect(median > SignalGrouper.turnsCorrelation, "\(median)")
        let found = Self.signals(iq, pointHz: -300)
        #expect(!found.contains { $0.tones != nil }, "\(Self.describe(found))")
    }

    static let alternationOverlap = 0.05

    @Test func fskWithFadingOnOneTone() throws {
        let spec = SynthSpec.rtty(baud: 75, shiftHz: 850)
        let iq = SignalSynth.make(spec, sampleRate: Self.rate, seconds: 3, snrDb: 20, offsetHz: 1000, seed: 7,
                                  impairments: SignalSynth.fading(toneIndex: 0, depthDb: 10))
        let found = Self.signals(iq, pointHz: 1000 + 425)
        #expect(found.count == 1 && found.first?.tones?.count == 2, "\(Self.describe(found))")
        let id = Self.identified(iq, centerHz: 11_000_000, pointHz: 1000 + 425)
        #expect(id.label.hasPrefix("2-FSK · 75"), "\(id.label)")
    }

    /// 2-FSK with one tone `db` under the other throughout, as selective fading can leave it for seconds at a time.
    static func imbalanced(baud: Double, shift: Double, db: Double, snr: Double, seed: UInt64, seconds: Double = 3) -> [Float] {
        let n = Int(rate * seconds)
        var random = SynthRandom(seed: seed, stream: 21)
        var out = [Float](repeating: 0, count: 2 * n)
        let weak = Float(pow(10, -db / 20))
        var phase = 0.0, k = 0, edge = 0.0
        while k < n {
            let low = random.int(2) == 0
            edge += rate / baud
            let end = min(n, Int(edge))
            let step = 2 * Double.pi * (low ? -shift / 2 : shift / 2) / rate
            let level = low ? weak : 1
            while k < end {
                phase += step
                out[2 * k] = level * Float(cos(phase))
                out[2 * k + 1] = level * Float(sin(phase))
                k += 1
            }
        }
        var noise = SynthRandom(seed: seed, stream: 22)
        SynthNoise.add(to: &out, power: pow(10, -snr / 10) * rate / (shift + 2 * baud), random: &noise)
        return out
    }

    /// A tone well under the other is still a tone. In the CW sub-band too, where the strong tone alone would read as
    /// keying: the tones' own answer goes first.
    @Test(arguments: [(50.0, 425.0, 13.0, UInt64(13)), (75, 850, 16, 26), (45.45, 170, 13, 39)]) func aWeakToneIsStillATone(baud: Double, shift: Double, db: Double, seed: UInt64) {
        let iq = Self.imbalanced(baud: baud, shift: shift, db: db, snr: 25, seed: seed)
        let id = Self.identified(iq, centerHz: 14_030_000, pointHz: shift / 2)
        #expect(Self.isRight(id, baud: baud, shift: shift), "\(baud)/\(shift), \(db) dB down: \(IdentifyTests.describe(id))")
    }

    /// One tone constantly under the other: how often it reads as what it is, and the wrong names, for the report.
    @Test(.enabled(if: Sweep.full)) func imbalanceTable() {
        var tally: [Double: (right: Int, total: Int, wrong: Int)] = [:]
        for (baud, shift) in [(45.45, 170.0), (50, 425), (75, 850)] {
            for rf in [11_000_000.0, 14_030_000, 14_085_000] {
                for snr in [20.0, 30] {
                    for db in [6.0, 10, 13, 16, 20] {
                        for seed in 1...UInt64(6) {
                            let id = Self.identified(Self.imbalanced(baud: baud, shift: shift, db: db, snr: snr, seed: seed * 13),
                                                     centerHz: rf, pointHz: shift / 2)
                            let m = id.measurement
                            tally[db, default: (0, 0, 0)].total += 1
                            if m.family == .fsk, let s = m.fskShiftHz, abs(s - shift) <= 0.03 * shift { tally[db, default: (0, 0, 0)].right += 1 }
                            if let best = id.best, best.name != "RTTY", best.name != "NAVTEX / SITOR-B" { tally[db, default: (0, 0, 0)].wrong += 1 }
                        }
                    }
                }
            }
        }
        for db in tally.keys.sorted() {
            print("imbalanceTable \(db) dB down: \(tally[db]!.right)/\(tally[db]!.total) right, \(tally[db]!.wrong) wrong names")
        }
        for db in [6.0, 10, 13] { #expect(tally[db]?.right == tally[db]?.total, "\(db) dB down") }
    }

    /// FM's lines: voice and tones never take turns on the map, whatever their levels.
    @Test func fmIsNotGrouped() {
        let cases: [(SynthSpec, Double)] = [(.nfmVoice(), 15), (.fm(.voice(lowHz: 300, highHz: 3000), deviationHz: 500), 40), (.fm(.tone(1000), deviationHz: 500), 25)]
        for (index, c) in Sweep.cases(cases, default: [1]) {
            let rate = max(Self.rate, 2 * c.0.minimumSampleRate)
            let iq = SignalSynth.make(c.0, sampleRate: rate, seconds: 3, snrDb: c.1, seed: UInt64(40 + index))
            let hood = SignalIdentifier.neighbourhood(iq, sampleRate: rate, pointHz: 0)
            let found = SignalIdentifier.candidates(hood, view: TraceFinder.find(hood.map), pointHz: 0, radiusHz: 60)
            #expect(!found.contains { $0.tones != nil }, "\(c.0): \(Self.describe(found))")
        }
    }

    /// An FM transmitter keyed on and off by a tone, at an index that nulls its carrier, leaving a trace of carrier when the
    /// key is up: carrier and sideband really do take turns, on separate lines 23 dB apart in level. That is no 2-FSK.
    /// (This is what the level guard is for: unkeyed FM never gets this far, `fmIsNotGrouped`.)
    @Test func fmCarrierAndSidebandAreNotTones() throws {
        let tone = 1200.0, n = Int(3 * Self.rate), symbol = Int(Self.rate / 10)
        var random = SynthRandom(seed: 42, stream: 3)
        var frequency = [Double](repeating: 0, count: n)
        var on = false
        for k in 0..<n {
            if k % symbol == 0 { on = random.int(2) == 1 }
            if on { frequency[k] = 2.405 * tone * cos(2 * .pi * tone * Double(k) / Self.rate) }
        }
        var x = SynthDSP.frequencyModulate(frequency, rate: Self.rate, random: &random)
        for k in 0..<n where frequency[k] == 0 {
            x.re[k] *= 0.02
            x.im[k] *= 0.02
        }
        let iq = Self.interleaved(x, noisePower: 0.02, seed: 42)
        let map = Self.turnsMap(iq, pointHz: 0)
        // They do take turns: only their levels part them.
        #expect(Self.series(map, 0).turns(with: Self.series(map, tone)) != nil)
        let found = Self.signals(iq, pointHz: 0)
        #expect(found.contains { $0.kind == .single && ($0.lowerHz...$0.upperHz).contains(0) }, "\(Self.describe(found))")
        #expect(!found.contains { $0.tones?.contains { abs($0) < 30 } == true }, "\(Self.describe(found))")
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

    /// The real FSK's tones stand as two traces with an empty gap: the point in that gap has no line in its radius.
    @Test func thePointBetweenTheTonesIsOnTheSignal() throws {
        let clip = try #require(try RealCorpus.clips().first { $0.name == "11.7MHz-tuning" })
        let stop = 2 * Int(9 * clip.rate)
        let iq = Array(clip.iq[(stop - 2 * Int(3 * clip.rate))..<stop])
        let middle = 11_688_221.5 - clip.centerHz
        let hood = SignalIdentifier.neighbourhood(iq, sampleRate: clip.rate, pointHz: middle)
        let view = TraceFinder.find(hood.map)
        #expect(!view.traces.contains { max(0, $0.lowerHz - middle, middle - $0.upperHz) <= 60 }
            && !view.areas.contains { $0.lowerHz...$0.upperHz ~= middle }, "\(TraceFinderTests.describe(view))")
        let id = SignalIdentifier.identify(iq: iq, sampleRate: clip.rate, captureCenterHz: clip.centerHz, atHz: 11_688_221.5,
                                           bandwidthHz: nil, spectrumDb: nil, longer: nil)
        #expect(id.label.hasPrefix("2-FSK · 75"), "\(id.label)")
    }

    /// ... but the gap between stations that ignore each other is empty.
    @Test func theGapBetweenUnrelatedStationsIsEmpty() {
        var iq = SignalSynth.make(.cw(wpm: 20), sampleRate: Self.rate, seconds: 3, snrDb: 25, offsetHz: -400, seed: 44)
        let other = SignalSynth.make(.cw(wpm: 20), sampleRate: Self.rate, seconds: 3, snrDb: 25, offsetHz: 400, seed: 45)
        for k in iq.indices { iq[k] += other[k] }
        let id = Self.identified(iq, centerHz: 11_000_000, pointHz: 0)
        #expect(id.note == SignalIdentifier.noSignalNote && id.best == nil, "\(id.label)")
        var carriers = SignalSynth.make(.noise, sampleRate: Self.rate, seconds: 3, snrDb: 0, seed: 46)
        TraceFinderTests.addCarrier(to: &carriers, offsetHz: -400, amplitude: 0.3)
        TraceFinderTests.addCarrier(to: &carriers, offsetHz: 400, amplitude: 0.3)
        let gap = Self.identified(carriers, centerHz: 11_000_000, pointHz: 0)
        #expect(gap.note == SignalIdentifier.noSignalNote && gap.best == nil, "\(gap.label)")
    }

    // MARK: Stations inside an FSK's span

    /// A CW station in the gap of an FSK loud enough for its skirts to fill it: it stays a signal, the point on it answers
    /// it, and the FSK's reading isn't pulled by it.
    @Test(arguments: [(45.45, 850.0, 200.0), (45.45, 850, 300), (45.45, 425, 100)]) func aStationInTheGapIsItsOwn(baud: Double, shift: Double, cw: Double) throws {
        var named = 0, seen = 0
        for seed in Sweep.full ? Array(1...UInt64(8)) : [1] {
            var iq = SignalSynth.make(.rtty(baud: baud, shiftHz: shift), sampleRate: Self.rate, seconds: 3, snrDb: 25, seed: seed)
            let station = SignalSynth.render(.cw(wpm: 20), sampleRate: Self.rate, seconds: 3, offsetHz: cw, seed: seed + 50)
            for k in iq.indices { iq[k] += station[k] }
            let rf = 14_085_000.0
            let onStation = Self.identified(iq, centerHz: rf, pointHz: cw)
            // The name for what's under the pointer is never the FSK's.
            #expect(onStation.best?.name != "RTTY" && onStation.measurement.fskShiftHz == nil,
                    "seed \(seed): \(IdentifyTests.describe(onStation))")
            let found = Self.signals(iq, pointHz: cw)
            if found.contains(where: { $0.kind == .single && ($0.lowerHz...$0.upperHz).contains(cw) }) {
                seen += 1
                if onStation.best?.name == "CW" { named += 1 }
            }
            let onTone = Self.identified(iq, centerHz: rf, pointHz: shift / 2)
            #expect(Self.isRight(onTone, baud: baud, shift: shift), "seed \(seed): \(IdentifyTests.describe(onTone))")
        }
        #expect(seen >= 1 && named == seen, "named CW \(named) of \(seen) where it stood alone")
    }

    /// The real FSK with a carrier in its gap: the carrier stays apart, and the tones still read.
    @Test func aCarrierInTheRealFSKsGap() throws {
        let clip = try #require(try RealCorpus.clips().first { $0.name == "11.7MHz-tuning" })
        let low = 11_687_797 - clip.centerHz, high = 11_688_646 - clip.centerHz
        for end in Sweep.full ? [3.0, 6.0, 9.0, 12.0] : [9.0] {
            let stop = 2 * Int(end * clip.rate)
            let base = Array(clip.iq[(stop - 2 * Int(3 * clip.rate))..<stop])
            let toneChannel = Channel.extract(base, sampleRate: clip.rate, offsetHz: low, bandwidthHz: 100)
            let tonePower = toneChannel.samples.reduce(0.0) { $0 + Double($1.real * $1.real + $1.imag * $1.imag) } / Double(toneChannel.samples.count)
            for relativeDb in [6.0, 0] {
                var iq = base
                TraceFinderTests.addCarrier(to: &iq, offsetHz: low + 300, rate: clip.rate,
                                            amplitude: Float(tonePower.squareRoot() * pow(10, relativeDb / 20)))
                func at(_ hz: Double) -> SignalIdentity {
                    SignalIdentifier.identify(iq: iq, sampleRate: clip.rate, captureCenterHz: clip.centerHz, atHz: clip.centerHz + hz,
                                              bandwidthHz: nil, spectrumDb: nil, longer: nil)
                }
                let carrier = at(low + 300)
                #expect(carrier.measurement.family == .carrier, "to \(end) s, \(relativeDb) dB: \(IdentifyTests.describe(carrier))")
                let tone = at(high)
                #expect(tone.label.hasPrefix("2-FSK · 75"), "to \(end) s, \(relativeDb) dB: \(IdentifyTests.describe(tone))")
            }
        }
    }

    /// A strong neighbour inside the channel's room is taken out before the reading: it would otherwise count as the
    /// signal's power, or get into a tone's filter.
    @Test func aStrongNeighbourInTheChannelIsNotched() throws {
        let spec = SynthSpec.rtty(baud: 100, shiftHz: 850)
        var iq = SignalSynth.make(spec, sampleRate: Self.rate, seconds: 3, snrDb: 20, seed: 42)
        TraceFinderTests.addCarrier(to: &iq, offsetHz: 425 + 190, amplitude: 5)
        let fsk = SignalCandidate(kind: .fsk(tones: [-425, 425]), lowerHz: -425, upperHz: 425, traces: [])
        let carrier = SignalCandidate(kind: .single, lowerHz: 600, upperHz: 630, traces: [])
        let tones = try #require(DirectFSK.Tones(fsk, signals: [fsk, carrier], noiseDb: Self.noiseDb(spec, snrDb: 20)))
        let read = try #require(tones.reading(iq, rate: Self.rate, zeroHz: 0))
        #expect(abs(read.reading.snrDb - 20) <= 3, "\(read)")
        #expect(abs((read.reading.baud ?? 0) - 100) <= 1, "\(read)")
        #expect(abs((read.reading.shiftHz ?? 0) - 850) <= 25, "\(read)")
    }

    /// ... and what lies on a tone isn't taken for a neighbour, or the tone would go with it.
    @Test func aSkirtOnAToneIsNotNotched() throws {
        let fsk = SignalCandidate(kind: .fsk(tones: [-425, 425]), lowerHz: -425, upperHz: 425, traces: [])
        let skirt = SignalCandidate(kind: .single, lowerHz: 440, upperHz: 450, traces: [])
        let away = SignalCandidate(kind: .single, lowerHz: 600, upperHz: 630, traces: [])
        let tones = try #require(DirectFSK.Tones(fsk, signals: [fsk, skirt, away], noiseDb: -40))
        #expect(tones.othersHz == [600...630])
    }

    /// What the agents ask: an honoured width, with a whole FSK inside it, gets the FSK's own answer, no wider.
    @Test(arguments: [900.0, 1500, 2000]) func aGivenWidthHoldingTheFSK(width: Double) throws {
        let clip = try #require(try RealCorpus.clips().first { $0.name == "11.7MHz-tuning" })
        let stop = 2 * Int(9 * clip.rate)
        let iq = Array(clip.iq[(stop - 2 * Int(3 * clip.rate))..<stop])
        let id = SignalIdentifier.identify(iq: iq, sampleRate: clip.rate, captureCenterHz: clip.centerHz, atHz: 11_688_221.5,
                                           bandwidthHz: width, spectrumDb: nil, longer: nil)
        #expect(id.label.hasPrefix("2-FSK · 75"), "\(IdentifyTests.describe(id))")
        #expect(id.measurement.occupiedBandwidthHz <= width, "\(IdentifyTests.describe(id))")
    }

    /// A width with only one tone inside it isn't the FSK: the old measurement, inside the width.
    @Test func aGivenWidthHoldingOneToneIsNotTheFSK() throws {
        let clip = try #require(try RealCorpus.clips().first { $0.name == "11.7MHz-tuning" })
        let stop = 2 * Int(9 * clip.rate)
        let iq = Array(clip.iq[(stop - 2 * Int(3 * clip.rate))..<stop])
        let id = SignalIdentifier.identify(iq: iq, sampleRate: clip.rate, captureCenterHz: clip.centerHz, atHz: 11_687_797,
                                           bandwidthHz: 300, spectrumDb: nil, longer: nil)
        #expect(id.measurement.fskShiftHz == nil && id.measurement.occupiedBandwidthHz <= 300, "\(IdentifyTests.describe(id))")
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

    /// A reading of more than 8 tones is `mfsk`, and 8 still `fsk`.
    @Test func manyTonesAreMFSK() {
        for (tones, family) in [(8, SignalFamily.fsk), (16, .mfsk)] {
            let read = FSKReading(toneCount: tones, shiftHz: nil, spacingHz: 100, baud: 10, baudConfidence: 1, snrDb: 20)
            #expect(SignalMeasurer.measurement(read, offsetHz: 0, seconds: 3).family == family)
        }
    }

    /// Two tones lost in something wider between them: that is no FSK's power, so it is no FSK.
    @Test func tonesInsideSomethingWiderAreNoFSK() {
        let rate = 12_000.0
        let spec = SynthSpec.rtty(baud: 50, shiftHz: 850)
        let quiet = SignalSynth.render(spec, sampleRate: rate, seconds: 3, seed: 47)
        var iq = TraceFinderTests.shaped(rate: rate, seconds: 3, seed: 48) { abs($0) < 300 ? 60 : 0.001 }
        for k in iq.indices { iq[k] += 0.5 * quiet[k] }
        let reading = DirectFSK.measure(Self.complex(iq), rate: rate, tonesHz: [-425, 425], noiseDb: 10 * log10(0.001 / rate))
        #expect(reading == nil, "\(String(describing: reading))")
    }

    /// Tones changing with no clock behind them: the runs may fall near whole numbers, but no line stands for them.
    @Test(arguments: [UInt64(1), 3, 4, 5, 7]) func keyingWithoutAClockHasNoSpeed(seed: UInt64) throws {
        let rate = 12_000.0
        var random = SynthRandom(seed: seed, stream: 3)
        let n = Int(3 * rate)
        var frequency: [Double] = []
        var tone = 425.0
        while frequency.count < n {
            let run = 0.02 * random.uniform(0.8...1.2) * Double(1 + random.int(3))
            frequency += [Double](repeating: tone, count: Int(run * rate))
            tone = -tone
        }
        let iq = Self.interleaved(SynthDSP.frequencyModulate(Array(frequency.prefix(n)), rate: rate, random: &random), noisePower: 0.05, seed: seed)
        let reading = try #require(DirectFSK.measure(Self.complex(iq), rate: rate, tonesHz: [-425, 425], noiseDb: 10 * log10(0.05 / rate)))
        #expect(reading.baud == nil, "\(reading)")
        #expect(abs((reading.shiftHz ?? 0) - 850) <= 25, "\(reading)")
    }

    static func interleaved(_ x: Baseband, noisePower: Double, seed: UInt64) -> [Float] {
        var iq = [Float](repeating: 0, count: 2 * x.count)
        for k in 0..<x.count {
            iq[2 * k] = x.re[k]
            iq[2 * k + 1] = x.im[k]
        }
        var noise = SynthRandom(seed: seed, stream: 8)
        SynthNoise.add(to: &iq, power: noisePower, random: &noise)
        return iq
    }

    /// Tones given in the wrong place that hear the wrong thing: they may not come back moved past each other, or far.
    @Test func tonesThatHeardSomethingElseAreRejected() {
        let rate = 12_000.0
        let spec = SynthSpec.rtty(baud: 50, shiftHz: 850)
        let iq = SignalSynth.make(spec, sampleRate: rate, seconds: 3, snrDb: 25, seed: 49)
        for tones in [[-600.0, -500], [250, 350], [-550, -350], [75, 275]] {
            let reading = DirectFSK.measure(Self.complex(iq), rate: rate, tonesHz: tones, noiseDb: Self.noiseDb(spec, snrDb: 25))
            #expect(reading == nil, "\(tones): \(String(describing: reading))")
        }
    }

    /// The newest 3 s hold too few changes to show a speed, and what they hold doesn't name itself.
    static func slowingFSK(seed: UInt64) -> (iq: [Float], rate: Double, newest: [Float]) {
        let rate = 12_000.0
        var random = SynthRandom(seed: seed, stream: 3)
        let total = Int(16 * rate), fast = Int(13 * rate)
        var frequency: [Double] = []
        // The low tone 6 dB down, which the measurer's own reading can't follow on this keying.
        // Start-stop keying first: its line lies at twice its speed.
        while frequency.count < fast {
            func hold(_ hz: Double, _ symbols: Double) { frequency += [Double](repeating: hz, count: Int((symbols / 45.45 * rate).rounded())) }
            hold(-425, 1)
            for _ in 0..<5 { hold(random.int(2) == 1 ? 425 : -425, 1) }
            hold(425, 1.5)
        }
        var tone = 425.0
        while frequency.count < total {
            frequency += [Double](repeating: tone, count: Int(random.uniform(0.2...0.9) * rate))
            tone = -tone
        }
        var x = SynthDSP.frequencyModulate(Array(frequency.prefix(total)), rate: rate, random: &random)
        for k in 0..<total where frequency[k] < 0 {
            x.re[k] *= 0.5
            x.im[k] *= 0.5
        }
        let iq = interleaved(x, noisePower: 0.02, seed: seed)
        return (iq, rate, Array(iq.suffix(2 * Int(3 * rate))))
    }

    /// Tones that take turns without showing a speed: with no longer read, the shift, and a longer read asked for. With
    /// one, the speed it shows.
    @Test func noSpeedYetThenTheLongerRead() {
        let (iq, rate, newest) = Self.slowingFSK(seed: 50)
        func identify(_ longer: (() -> (iq: [Float], seconds: Double)?)?) -> SignalIdentity {
            SignalIdentifier.identify(iq: newest, sampleRate: rate, captureCenterHz: 11_000_000, atHz: 11_000_425, bandwidthHz: nil,
                                      spectrumDb: nil, longer: longer)
        }
        let first = identify(nil)
        #expect(first.label == "2-FSK · 850 Hz shift", "\(IdentifyTests.describe(first))")
        #expect(first.needsLongerRead, "\(IdentifyTests.describe(first))")
        let long = identify { (iq, 16) }
        #expect(abs((long.measurement.symbolRate ?? 0) - 45.45) <= 0.01 * 45.45, "\(IdentifyTests.describe(long))")
        #expect(abs((long.measurement.fskShiftHz ?? 0) - 850) <= 25, "\(IdentifyTests.describe(long))")
        #expect(!long.needsLongerRead)
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
            // From the tones' own path, not a measurer that happens to read the same range.
            #expect(id.measurement.fskShiftHz != nil && id.measurement.notes.contains { $0.contains("take turns") },
                    "\(IdentifyTests.describe(id))")
        }
    }

    // MARK: Names

    @Test func ttyOutsideHamBandsStaysFSK() {
        let iq = SignalSynth.make(.rtty(baud: 75, shiftHz: 850), sampleRate: Self.rate, seconds: 3, snrDb: 20, seed: 15)
        let id = Self.identified(iq, centerHz: 11_688_000, pointHz: 425)
        #expect(id.best == nil, "\(IdentifyTests.describe(id))")
        #expect(id.label.hasPrefix("2-FSK · 75"), "\(id.label)")
        // Its SNR, from the view's noise.
        #expect(abs(id.measurement.snrDb - 20) <= 3, "\(IdentifyTests.describe(id))")
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

    /// CW whose key thumps: every edge rings at ±400 Hz, so its clicks stand as separate humps, tried as tones. They run
    /// with the key, not against it.
    @Test func cornerCaseCWIsNotFSK() throws {
        var iq = SignalSynth.make(.noise, sampleRate: Self.rate, seconds: 3, snrDb: 0, seed: 17)
        let unit = Int(0.06 * Self.rate), n = iq.count / 2
        var random = SynthRandom(seed: 17, stream: 6)
        var key = [Float]()
        while key.count < n {
            key += [Float](repeating: 1, count: unit * (random.int(2) == 1 ? 3 : 1))
            key += [Float](repeating: 0, count: unit * (random.int(3) == 0 ? 3 : 1))
        }
        // Each edge's ring, decaying over a few ms, as an amplitude on the key.
        var amplitude = Array(key.prefix(n))
        let ringFor = Int(0.024 * Self.rate), ring = 2 * Double.pi * 400 / Self.rate
        for k in 1..<n where key[k] != key[k - 1] {
            for j in 0..<min(ringFor, n - k) {
                amplitude[k + j] += 2 * Float(exp(-Double(j) / (0.008 * Self.rate)) * cos(ring * Double(j)))
            }
        }
        let step = 2 * Double.pi * 800 / Self.rate
        for k in 0..<n {
            iq[2 * k] += 0.5 * amplitude[k] * Float(cos(step * Double(k)))
            iq[2 * k + 1] += 0.5 * amplitude[k] * Float(sin(step * Double(k)))
        }
        // It really reaches the grouping: humps to try, on the point's span.
        let hood = SignalIdentifier.neighbourhood(iq, sampleRate: Self.rate, pointHz: 800)
        let view = TraceFinder.find(hood.map)
        let map = Self.turnsMap(iq, pointHz: 800)
        let average = TraceFinder.smoothed(hood.map.meanPower(), reach: Int((TraceFinder.traceReachHz / hood.map.binHz).rounded()))
        let spans = view.traces.map { $0.lowerHz...$0.upperHz } + view.areas.map { $0.lowerHz...$0.upperHz }
        let humps = spans.flatMap { SignalGrouper.peaks($0, average: average, lines: hood.map) }.filter { abs($0.hz - 800) <= 600 }
        #expect(humps.count >= 2, "\(TraceFinderTests.describe(view))")
        let found = SignalGrouper.group(view, map: map, lines: hood.map)
        #expect(!found.contains { $0.tones != nil }, "\(Self.describe(found))")
        let id = Self.identified(iq, centerHz: 14_030_000, pointHz: 800)
        #expect(id.measurement.fskShiftHz == nil, "\(IdentifyTests.describe(id))")
        #expect(id.measurement.family == .ook, "\(IdentifyTests.describe(id))")
        #expect(id.best?.name == "CW", "\(IdentifyTests.describe(id))")
    }

    /// A speed that is close to a whole number is shown as it, only within what a reading can tell.
    @Test func wholeSpeedsOnlyWithinTheirError() {
        let shown: [(Double, String)] = [(75, "75"), (74.98, "75"), (75.02, "75"), (45.45, "45.45"), (56.25, "56.25"), (93.75, "93.75"),
                                         (66.67, "66.67"), (45.22, "45.22"), (133.33, "133.33"), (187.5, "187.5"), (100, "100")]
        for (baud, text) in shown {
            let m = SignalMeasurement(occupiedBandwidthHz: 1000, snrDb: 20, envelope: .steady, family: .fsk, familyConfidence: 0.8,
                                      symbolRate: baud, fskShiftHz: 850, toneCount: 2, toneSpacingHz: 850, seconds: 3)
            let label = SignalIdentifier.identify(m, rfHz: 8_000_000).label
            #expect(label.hasPrefix("2-FSK · \(text) Bd"), "\(baud): \(label)")
        }
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

    /// Fast, strong keying can leave the picture with a pair of lobes, whose reading has plenty of changes and no speed.
    /// Its numbers mustn't reach the owner: better `Unknown` than the wrong shift.
    @Test(arguments: Sweep.full ? [(150.0, 425.0, UInt64(1), 40.0), (200, 850, 1, 40), (200, 850, 2, 40), (200, 1000, 1, 40), (200, 1000, 2, 40)]
           : [(200.0, 850.0, UInt64(1), 40.0)]) func lobesDoNotGiveAShift(baud: Double, shift: Double, seed: UInt64, snr: Double) {
        let iq = SignalSynth.make(.rtty(baud: baud, shiftHz: shift), sampleRate: Self.rate, seconds: 3, snrDb: snr, seed: seed * 1000 + UInt64(baud) + UInt64(shift),
                                  impairments: SignalSynth.fading(toneIndex: 0, depthDb: 10))
        let id = Self.identified(iq, centerHz: 11_000_000, pointHz: shift / 2)
        let m = id.measurement
        #expect(m.fskShiftHz.map { abs($0 - shift) <= 0.03 * shift } ?? true, "\(IdentifyTests.describe(id))")
    }

    /// A reading of a pair of lobes shouldn't pass for a speed either: without the fade too.
    @Test func lobesShowNoSpeed() {
        let iq = SignalSynth.make(.rtty(baud: 200, shiftHz: 1000), sampleRate: Self.rate, seconds: 3, snrDb: 40, seed: 1000 + 200 + 1000)
        let id = Self.identified(iq, centerHz: 11_000_000, pointHz: 500)
        #expect(id.measurement.fskShiftHz.map { abs($0 - 1000) <= 30 } ?? true, "\(IdentifyTests.describe(id))")
    }

    /// Lines that pass for tones and don't read as them are measured as what they are: an FM's Bessel lines, here.
    @Test(.enabled(if: Sweep.full), arguments: Array(1...UInt64(50))) func linesThatDoNotReadAsTonesStayWhatTheyAre(seed: UInt64) throws {
        let placement = try #require(IdentifyTests.placements.first { $0.name.hasPrefix("NOAA APT") })
        let id = IdentifyTests.identified(placement, snr: 20, seed: seed)
        #expect(id.best?.name.hasPrefix("NOAA APT") == true, "seed \(seed): \(IdentifyTests.describe(id))")
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
        var wrong: [String] = [], wrongNumbers: [String] = []
        for shift in [170.0, 200, 425, 450, 600, 850, 1000, 1400] {
            for baud in [45.45, 50, 56.25, 75, 100, 150, 200, 300] where shift / baud >= 1.5 {
                for snr in [40.0, 20, 12] {
                    for fade in [0.0, 10] {
                        for neighbour in Neighbour.allCases {
                            for seed in 1...UInt64(2) {
                                let iq = Self.capture(baud: baud, shift: shift, snr: snr, fade: fade, neighbour: neighbour,
                                                      seed: seed * 1000 + UInt64(baud) + UInt64(shift))
                                let id = Self.identified(iq, centerHz: 11_000_000, pointHz: shift / 2)
                                let right = Self.isRight(id, baud: baud, shift: shift)
                                if !right, let s = id.measurement.fskShiftHz, abs(s - shift) > 0.03 * shift {
                                    wrongNumbers.append("\(baud)/\(shift) \(snr) dB fade \(fade) \(neighbour): \(id.label)")
                                }
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
        // 40 dB, beside a carrier a further 20 dB up, is what the finder can't part (not this signal's own doing): it reads
        // `Carrier` or `Unknown`, honestly. The target is for what's below that.
        for key in ["12.0 dB", "20.0 dB"] {
            let t = tally[key] ?? (0, 1)
            #expect(Double(t.right) >= 0.9 * Double(t.total), "\(key): \(t)")
        }
        #expect(wrongNumbers.isEmpty, "\(wrongNumbers)")
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
