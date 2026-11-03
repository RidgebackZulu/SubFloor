import DSPCore
import Foundation
import Testing
@testable import SignalID

/// Looking around the point: what `TraceFinder` sees in a capture, and the answers `identify(iq:…)` gives from it.
@Suite(.serialized) struct TraceFinderTests {
    static let rate = 48_000.0

    /// The map and view of a whole capture centred on the point `pointHz` from its centre, as `identify(iq:…)` looks.
    static func view(_ iq: [Float], rate: Double = rate, pointHz: Double = 0)
        -> (map: TimeFrequencyMap, view: NeighbourhoodView) {
        let map = SignalIdentifier.neighbourhoodMap(iq, sampleRate: rate, pointHz: pointHz)
        return (map, TraceFinder.find(map))
    }

    static func describe(_ view: NeighbourhoodView) -> String {
        "traces " + view.traces.map { String(format: "%.0f…%.0f (%.1f dB)", $0.lowerHz, $0.upperHz, $0.snrDb) }
            .joined(separator: ", ")
            + "; areas " + view.areas.map { String(format: "%.0f…%.0f (%.1f dB)", $0.lowerHz, $0.upperHz, $0.snrDb) }
            .joined(separator: ", ")
    }

    /// A tone at `offsetHz` of amplitude 1 over interleaved `iq`.
    static func addCarrier(to iq: inout [Float], offsetHz: Double, rate: Double = rate, amplitude: Float = 1,
                           phase: Double = 0) {
        let step = 2 * Double.pi * offsetHz / rate
        for k in 0..<(iq.count / 2) {
            iq[2 * k] += amplitude * Float(cos(step * Double(k) + phase))
            iq[2 * k + 1] += amplitude * Float(sin(step * Double(k) + phase))
        }
    }

    /// A carrier's amplitude, `db` over the noise in a map bin, for noise of unit power over `rate`.
    static func amplitude(db: Double, rate: Double = rate) -> Float {
        Float((pow(10, db / 10) * 12 / rate).squareRoot())
    }

    /// Unit-power noise with its density shaped by `density(f)`, relative to that noise's own (FFT-shaped).
    static func shaped(rate: Double, seconds: Double, seed: UInt64, density: (Double) -> Double) -> [Float] {
        let n = Int(rate * seconds)
        let size = FFT.size(atLeast: n)
        var random = SynthRandom(seed: seed, stream: 3)
        var noise = [Float](repeating: 0, count: 2 * size)
        SynthNoise.add(to: &noise, power: 1, random: &random)
        var re = (0..<size).map { noise[2 * $0] }, im = (0..<size).map { noise[2 * $0 + 1] }
        FFT.transform(&re, &im)
        for k in 0..<size {
            let f = k < size / 2 ? Double(k) * rate / Double(size) : Double(k - size) * rate / Double(size)
            let a = Float(density(f).squareRoot())
            re[k] *= a
            im[k] *= a
        }
        FFT.transform(&re, &im, inverse: true)
        let scale = 1 / Float(size)
        var out = [Float](repeating: 0, count: 2 * n)
        for k in 0..<n {
            out[2 * k] = re[k] * scale
            out[2 * k + 1] = im[k] * scale
        }
        return out
    }

    static func identified(_ iq: [Float], rate: Double = rate, pointHz: Double) -> SignalIdentity {
        SignalIdentifier.identify(iq: iq, sampleRate: rate, captureCenterHz: 7_000_000, atHz: 7_000_000 + pointHz,
                                  bandwidthHz: nil, spectrumDb: nil, longer: nil)
    }

    /// Empty points on the tuning part of the corpus say `No signal`, and nothing grows wide.
    @Test func emptyPointsSayNoSignal() throws {
        let points = try RealCorpus.points(.tuning).filter { $0.truth == "none" }
        var answers: [String] = []
        let score = try RealCorpus.score(points: points) { clip, point in
            let id = RealCorpus.hover(clip, point)
            #expect(id.measurement.occupiedBandwidthHz <= 100_000, "\(point.atHz): \(id.label)")
            if !RealCorpus.isRight(id, point) { answers.append("\(point.clip) \(point.atHz) \(point.endSeconds): \(id.label)") }
            return id
        }
        let none = try #require(score["none"])
        print("emptyPointsSayNoSignal: \(none.right)/\(none.total); \(answers)")
        #expect(Double(none.right) >= 0.95 * Double(none.total), "\(none.right)/\(none.total): \(answers)")
    }

    /// Noise that jumps 6 dB across the whole band, as a receiver's gain does: no trace, no area, and no signal.
    @Test func levelJumpIsNotASignal() {
        let noise = SignalSynth.make(.noise, sampleRate: Self.rate, seconds: 3, snrDb: 0, seed: 301)
        let iq = SignalSynth.levelStep(noise, sampleRate: Self.rate, atSeconds: 1.4, db: 6)
        let seen = Self.view(iq, pointHz: 3000)
        #expect(seen.view.traces.isEmpty && seen.view.areas.isEmpty, "\(Self.describe(seen.view))")
        let id = SignalIdentifier.identify(iq: iq, sampleRate: Self.rate, captureCenterHz: 7_000_000, atHz: 7_003_000,
                                           bandwidthHz: nil, spectrumDb: nil, longer: nil)
        #expect(id.note == SignalIdentifier.noSignalNote, "\(IdentifyTests.describe(id))")
    }

    /// Two carriers 300 Hz apart are two traces.
    @Test func twoCarriersAreTwoTraces() {
        var iq = SignalSynth.make(.noise, sampleRate: Self.rate, seconds: 3, snrDb: 0, seed: 302)
        // About 22 dB over the noise in a map bin (unit noise power over 48 kHz: −36 dB in the frame's 12 Hz).
        Self.addCarrier(to: &iq, offsetHz: 3000, amplitude: 0.2)
        Self.addCarrier(to: &iq, offsetHz: 3300, amplitude: 0.2)
        let seen = Self.view(iq, pointHz: 3150)
        #expect(seen.view.traces.count == 2, "\(Self.describe(seen.view))")
        #expect(seen.view.areas.isEmpty, "\(Self.describe(seen.view))")
        #expect(seen.view.traces.allSatisfy { $0.steady }, "\(Self.describe(seen.view))")
    }

    /// FT8's tones hop within about 50 Hz: one trace, however they hop, and it isn't steady.
    @Test func ft8ToneHopsStayInOneTrace() throws {
        let iq = SignalSynth.make(.ft8(captureStartInSlot: 2), sampleRate: Self.rate, seconds: 3, snrDb: 20,
                                  offsetHz: 1500, seed: 303)
        let seen = Self.view(iq, pointHz: 1500)
        #expect(seen.view.traces.count == 1, "\(Self.describe(seen.view))")
        let trace = try #require(seen.view.traces.first)
        let width = trace.upperHz - trace.lowerHz
        #expect((40...70).contains(width), "\(width) Hz: \(Self.describe(seen.view))")
        #expect(!trace.steady)
    }

    /// The real voice (HFGCS at 11.175 MHz, USB): an area as wide as its audio, with no trace inside it.
    @Test func voiceIsAnArea() throws {
        let capture = try IdentifyTests.iqFixture("SubFloor_20261027_150938Z_IQ_11178000Hz_62500Sps_7.5s")
        for end in Sweep.full ? [4.5, 6.0, 7.5] : [6.0] {
            let slice = Array(capture.iq[(2 * Int((end - 3) * capture.rate))..<(2 * Int(end * capture.rate))])
            let seen = Self.view(slice, rate: capture.rate, pointHz: -1500)
            let area = seen.view.areas.first { $0.lowerHz...$0.upperHz ~= -1500 }
            #expect(area != nil, "to \(end) s: \(Self.describe(seen.view))")
            guard let area else { continue }
            #expect((2000...3200).contains(area.upperHz - area.lowerHz), "to \(end) s: \(Self.describe(seen.view))")
            #expect(!seen.view.traces.contains { $0.lowerHz < area.upperHz && $0.upperHz > area.lowerHz },
                    "to \(end) s: \(Self.describe(seen.view))")
        }
    }

    /// An agent's width at the corpus FSK is honoured: the strong neighbour 2 kHz below isn't taken in.
    @Test func givenWidthIsNotGrown() throws {
        let clips = try RealCorpus.clips()
        let clip = try #require(clips.first { $0.name == "11.7MHz-tuning" })
        let middle = 11_688_221.5
        for end in Sweep.full ? [6.0, 9.0, 12.0] : [9.0] {
            let stop = 2 * Int(end * clip.rate)
            let iq = Array(clip.iq[(stop - 2 * Int(3 * clip.rate))..<stop])
            let id = SignalIdentifier.identify(iq: iq, sampleRate: clip.rate, captureCenterHz: clip.centerHz, atHz: middle,
                                               bandwidthHz: 900, spectrumDb: nil, longer: nil)
            let m = id.measurement
            #expect(m.occupiedBandwidthHz > 0 && m.occupiedBandwidthHz <= 1100, "to \(end) s: \(IdentifyTests.describe(id))")
            let neighbour = 11_685_864 - clip.centerHz
            let lower = m.offsetHz - m.occupiedBandwidthHz / 2
            #expect(lower > neighbour + 500, "to \(end) s: \(IdentifyTests.describe(id))")
        }
    }

    /// A very wide answer needs positive evidence. A real receiver's passband, noise in it from a 1 MS/s capture of the
    /// corpus, has none; WFM (no sharp edges, but a constant envelope) and DAB (sharp edges) do.
    @Test func wideAnswersNeedEvidence() throws {
        let rate = 1_000_000.0
        let noise = SignalSynth.make(.noise, sampleRate: rate, seconds: 0.25, snrDb: 0, seed: 305)
        for clip in try RealCorpus.clips().filter({ $0.part == .tuning }) {
            for pointHz in [-300_000.0, 50_000, 350_000] {
                let wide = WideOccupancy.find(clip.captureSpectrumDb, iq: noise, sampleRate: clip.captureRate, pointHz: pointHz)
                #expect(wide == nil, "\(clip.name) at \(pointHz): \(String(describing: wide))")
            }
        }
        let wfm = SignalSynth.make(.wfmBroadcast, sampleRate: rate, seconds: 0.4, snrDb: 10, offsetHz: 100_000, seed: 306)
        let found = WideOccupancy.find(SignalIdentifier.wideSpectrum(wfm, sampleRate: rate), iq: wfm, sampleRate: rate,
                                       pointHz: 100_000)
        #expect(found.map { abs($0.offsetHz - 100_000) < 20_000 && $0.widthHz > 48_000 } == true, "\(String(describing: found))")
        // DAB, named by `eachRowIsNamed`, reaches here too.
        guard Sweep.full else { return }
        let dab = SignalSynth.make(.dab, sampleRate: 2_048_000, seconds: 0.3, snrDb: 20, seed: 307)
        let block = WideOccupancy.find(SignalIdentifier.wideSpectrum(dab, sampleRate: 2_048_000), iq: dab,
                                       sampleRate: 2_048_000, pointHz: 0)
        #expect(block.map { abs($0.widthHz - 1_536_000) < 50_000 } == true, "\(String(describing: block))")
    }

    /// A strong carrier elsewhere in the capture is no evidence for a wide signal at an empty point, however strong.
    @Test func aCarrierElsewhereBringsNoWideAnswer() {
        let rate = 1_000_000.0
        let noise = SignalSynth.make(.noise, sampleRate: rate, seconds: 1, snrDb: 0, seed: 308)
        for times in Sweep.full ? [1.0, 3, 10, 30, 100] : [3, 100] {
            var iq = noise
            Self.addCarrier(to: &iq, offsetHz: 120_000, rate: rate, amplitude: Float(times.squareRoot()))
            let id = Self.identified(iq, rate: rate, pointHz: 0)
            #expect(id.note == SignalIdentifier.noSignalNote && id.measurement.occupiedBandwidthHz == 0,
                    "carrier at \(times) × the noise: \(IdentifyTests.describe(id))")
        }
    }

    /// Unrelated carriers beside a strong one never join it, through `identify`.
    @Test(arguments: Sweep.full ? [(-300.0, 340.0), (-500, 600), (-800, 950), (-300, 500), (-200, 450), (-300, 800)]
        : [(-300.0, 340.0), (-300, 500)])
    func unrelatedCarriersDontMerge(below: Double, above: Double) {
        for seed in Sweep.seeds(309...311) {
            var iq = SignalSynth.make(.noise, sampleRate: Self.rate, seconds: 3, snrDb: 0, seed: seed)
            Self.addCarrier(to: &iq, offsetHz: 5000, amplitude: Self.amplitude(db: 45))
            Self.addCarrier(to: &iq, offsetHz: 5000 + below, amplitude: Self.amplitude(db: 25), phase: 1.1)
            Self.addCarrier(to: &iq, offsetHz: 5000 + above, amplitude: Self.amplitude(db: 25), phase: 2.3)
            let id = Self.identified(iq, pointHz: 5000)
            let m = id.measurement
            #expect(m.occupiedBandwidthHz > 0 && m.occupiedBandwidthHz < min(-below, above) / 2,
                    "\(below)/\(above) seed \(seed): \(m.occupiedBandwidthHz) Hz, \(IdentifyTests.describe(id))")
            #expect(abs(m.offsetHz - 5000) < 30, "\(below)/\(above) seed \(seed): at \(m.offsetHz)")
        }
    }

    /// Stations filling most of the view, and one between them: the noise level is the moment's noise, not the stations'.
    @Test(arguments: Sweep.full ? [10.0, 15, 20, 25] : [15]) func aCrowdedBandStillShowsItsStation(db: Double) {
        let rate = 125_000.0
        let iq = Self.shaped(rate: rate, seconds: 1.5, seed: 312) { f in
            if abs(f) <= 4000 { return pow(10, db / 10) }
            let spacing = 10_000.0, nearest = (f / spacing).rounded() * spacing
            return abs(f - nearest) <= 4000 ? 1000 : 1
        }
        let id = Self.identified(iq, rate: rate, pointHz: 0)
        #expect(id.note != SignalIdentifier.noSignalNote, "\(db) dB: \(IdentifyTests.describe(id))")
        #expect((5000...10_000).contains(id.measurement.occupiedBandwidthHz), "\(db) dB: \(IdentifyTests.describe(id))")
    }

    /// A block too wide for most of the view to be noise, and not wide enough to be over 48 kHz: it has an answer.
    @Test(arguments: Sweep.full ? [(30_000.0, 62_500.0), (40_000, 62_500), (40_000, 125_000), (46_000, 125_000)]
        : [(40_000.0, 125_000.0)])
    func aBlockFillingTheViewIsFound(width: Double, rate: Double) {
        let iq = Self.shaped(rate: rate, seconds: 1.5, seed: 313) { abs($0) <= width / 2 ? 100 : 1 }
        let id = Self.identified(iq, rate: rate, pointHz: 0)
        #expect(abs(id.measurement.occupiedBandwidthHz / width - 1) < 0.2, "\(width) Hz: \(IdentifyTests.describe(id))")
    }

    /// The map reaches a point in the capture's outer edges, right up to the capture's edge.
    @Test(arguments: Sweep.full ? [91_000.0, 94_000, 98_000] : [94_000]) func aSignalAtTheCapturesEdgeIsFound(offsetHz: Double) {
        let rate = 200_000.0
        var iq = SignalSynth.make(.noise, sampleRate: rate, seconds: 1, snrDb: 0, seed: 314)
        Self.addCarrier(to: &iq, offsetHz: offsetHz, rate: rate, amplitude: Self.amplitude(db: 40, rate: rate))
        let id = Self.identified(iq, rate: rate, pointHz: offsetHz)
        #expect(id.measurement.occupiedBandwidthHz > 0 && abs(id.measurement.offsetHz - offsetHz) < 100,
                "\(offsetHz): \(IdentifyTests.describe(id))")
    }

    /// A clear carrier 1 kHz from an empty point, inside the default window: "No signal" at any strength.
    @Test func aCarrierBesideThePointDoesNotMakeItTooWeak() {
        let noise = SignalSynth.make(.noise, sampleRate: Self.rate, seconds: 3, snrDb: 0, seed: 315)
        for db in Sweep.full ? [15.0, 20, 25, 30, 35, 45] : [20, 25, 45] {
            var iq = noise
            Self.addCarrier(to: &iq, offsetHz: 4000, amplitude: Self.amplitude(db: db))
            let id = Self.identified(iq, pointHz: 3000)
            #expect(id.note == SignalIdentifier.noSignalNote, "\(db) dB: \(IdentifyTests.describe(id))")
        }
    }

    /// A channel as wide as the rate has nothing to filter. Its transition used to come out zero and its filter's length
    /// infinite: the crash in this task's first failing run.
    @Test func aChannelAsWideAsTheRateIsTheInput() {
        let iq = SignalSynth.make(.carrier, sampleRate: 48_000, seconds: 0.2, snrDb: .infinity, offsetHz: 1000, seed: 316)
        let cut = Channel.extract(iq, sampleRate: 48_000, offsetHz: 0, bandwidthHz: 48_000, sharp: false)
        #expect(cut.rate == 48_000 && cut.samples.count == iq.count / 2)
    }

    /// A tone of ALE measured alone, its neighbour tones in the channel: the bursts' short runs once crashed the FSK
    /// search (a segment shorter than its smoothing span made an inverted range).
    @Test func oneToneOfManyIsMeasuredWithoutCrashing() {
        let index = IdentifyTests.placements.firstIndex { $0.name.hasPrefix("ALE") } ?? 0
        let p = IdentifyTests.placements[index]
        let (iq, _) = IdentifyTests.capture(p, snr: 20, seed: UInt64(1 + index % 50))
        let m = SignalMeasurer.measure(iq, sampleRate: p.sampleRate, offsetHz: p.offsetHz - 124, bandwidthHz: 208, seconds: 3,
                                       ceiling: .found(mayBeLine: true, within: -Double.infinity...Double.infinity))
        #expect(m.occupiedBandwidthHz > 0 && m.occupiedBandwidthHz < 1000, "\(m.occupiedBandwidthHz)")
    }

    /// Nothing is looked for beyond the radius: a strong carrier 2 kHz from an empty point leaves it empty.
    @Test func noSearchBeyondTheRadius() {
        var iq = SignalSynth.make(.noise, sampleRate: Self.rate, seconds: 3, snrDb: 0, seed: 304)
        Self.addCarrier(to: &iq, offsetHz: 5000, amplitude: 0.5)
        let id = SignalIdentifier.identify(iq: iq, sampleRate: Self.rate, captureCenterHz: 7_000_000, atHz: 7_003_000,
                                           bandwidthHz: nil, spectrumDb: nil, longer: nil, pointRadiusHz: 60)
        #expect(id.note == SignalIdentifier.noSignalNote && id.best == nil, "\(IdentifyTests.describe(id))")
        let on = SignalIdentifier.identify(iq: iq, sampleRate: Self.rate, captureCenterHz: 7_000_000, atHz: 7_005_000,
                                           bandwidthHz: nil, spectrumDb: nil, longer: nil, pointRadiusHz: 60)
        #expect(on.measurement.occupiedBandwidthHz > 0, "the carrier itself is found: \(IdentifyTests.describe(on))")
    }
}
