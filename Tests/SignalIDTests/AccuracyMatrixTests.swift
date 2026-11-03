import Foundation
import Testing
@testable import SignalID

/// The spec's accuracy targets on synthetic signals: every catalogue entry (every row of the mode tables, some in
/// several variants) at 20, 10, 6 and 3 dB, through `SignalIdentifier.identify(iq:…)` with the slow pass, on seeds
/// 1–50 (thresholds were tuned on seeds 1000–1099). Prints the confusion summary.
///
/// - At ≥ 10 dB: family right ≥ 95%; symbol rate within 1%, 2-FSK shift within 3%, bandwidth within 10% and FM
///   deviation within its tolerance in ≥ 95% of the cases that carry them; named right ≥ 90%. Bandwidth: against
///   the noise-free render of the same seed for randomly modulated families (ruling R8: voice, programme, APT and fax
///   video), CW and carriers at 20 dB only (R10), never for a mode wider than the view. Deviation: against the peak
///   the same seed's noise-free capture holds over the read (R17), within 15% for NFM voice (R9), 10% otherwise.
/// - At 3 dB: a wrong name at ≥ 0.7 in ≤ 2% of cases.
///
/// Both run only with `SUBFLOOR_SIGNALID_MATRIX=1` (ruling R32: a default run leaves them out, so it doesn't starve
/// the suites beside it; `IdentifyTests.eachRowIsNamed` names each row by default):
/// - the full matrix (`accuracyMatrix`): every SNR, 5 seeds a cell; its targets reach 95% at the spec's tolerances;
/// - the subset (`accuracySubset`, ruling R20's, once always on): 10 and 3 dB, one seed a cell, the captures of
///   96 kS/s or less. Its targets must reach 90% where they have 10 cases or more, and where they have fewer every
///   case must fall within twice its tolerance (rulings R23, R24);
/// - the scenes (`scenesHaveNoWrongNames`): the HF modes the owner listens for among neighbours, fading, on an
///   interference comb and through a receiver's level jumps, and groups of FT8, every signal at 3 dB: no wrong name.
@Suite(.serialized) struct AccuracyMatrixTests {
    static let snrs = [20.0, 10, 6, 3]
    static func seedsPerCell(full: Bool) -> Int { full ? 5 : 1 }
    static func cellSNRs(full: Bool) -> [Double] { full ? snrs : [10, 3] }

    /// One identification and the truths it is judged against.
    struct Outcome: Sendable {
        var placement: Int
        var snr: Double
        var seed: UInt64
        var identity: SignalIdentity
        var family: SignalFamily
        var rate: Double?
        var shift: Double?
        var bandwidth: Double?
        var deviation: (value: Double, tolerance: Double)?

        var name: String { IdentifyTests.placements[placement].name }
        var familyRight: Bool { identity.measurement.family == family }
        var named: String? { identity.best?.name }
        var wrongName: Bool { named != nil && named != name }
        static func within(_ value: Double?, _ truth: Double, _ tolerance: Double) -> Bool {
            guard let value else { return false }
            return abs(value / truth - 1) <= tolerance
        }
        /// Each target this case carries, and whether it was met (only judged when the family is right).
        var targets: [(String, Bool)] { targets(toleranceScale: 1) }

        /// The same, each tolerance scaled by `toleranceScale`.
        func targets(toleranceScale k: Double) -> [(String, Bool)] {
            guard familyRight else { return [] }
            let m = identity.measurement
            var out: [(String, Bool)] = []
            if let rate { out.append(("rate", Self.within(m.symbolRate, rate, k * 0.01))) }
            if let shift { out.append(("shift", Self.within(m.fskShiftHz, shift, k * 0.03))) }
            if let bandwidth { out.append(("bandwidth", Self.within(m.occupiedBandwidthHz, bandwidth, k * 0.10))) }
            if let deviation {
                out.append(("deviation", Self.within(m.fmDeviationHz, deviation.value, k * deviation.tolerance)))
            }
            return out
        }
    }

    /// The family a spec is.
    static func family(_ spec: SynthSpec) -> SignalFamily {
        switch spec {
        case .noise: .noise
        case .carrier: .carrier
        case .cw: .ook
        case .am: .am
        case .ssb(let upper, _, _): upper ? .usb : .lsb
        case .fm(_, let deviation): deviation >= 50_000 ? .wfm : .fm
        case .fsk(let f): f.tones > 8 ? .mfsk : .fsk
        case .psk: .psk
        case .ofdm: .ofdm
        case .bursts(let inner, _): family(inner)
        }
    }

    /// The symbol rate the measurement should report: the FSK's or PSK's, or a subcarrier's.
    static func rate(_ spec: SynthSpec) -> Double? {
        switch spec {
        case .fsk(let f): f.rate
        case .psk(let p): p.rate
        case .fm(.afsk(_, let f), _), .am(.afsk(_, let f), _): f.rate
        case .bursts(let inner, _): rate(inner)
        default: nil
        }
    }

    /// The width of the noise-free capture over the span the measurement read (ruling R8's per-seed truth), by
    /// the synthesiser's definition.
    static func noiseFreeWidth(_ p: IdentifyTests.Placement, seed: UInt64, seconds: Double) -> Double {
        let long = p.sampleRate <= 96_000 ? IdentifyTests.longSeconds : p.seconds
        let clean = SignalSynth.make(p.spec, sampleRate: p.sampleRate, seconds: long, snrDb: .infinity,
                                     offsetHz: p.offsetHz, seed: seed)
        let read = Array(clean.suffix(2 * Int(seconds * p.sampleRate)))
        var size = 256
        while size < 65_536 && p.sampleRate / Double(size) > p.spec.nominalBandwidthHz / 128 { size *= 2 }
        let db = PowerSpectrum.average(read, size: size, maxFrames: 4096, hop: size / 4)
        return OccupiedBandwidth.width(db, binHz: p.sampleRate / Double(size), start: 2 * p.spec.nominalBandwidthHz)
    }

    /// The peak deviation of the noise-free capture over the span the measurement read: its instantaneous
    /// frequency's 99.9th-percentile excursion from its mean (the measurer's definition of the peak).
    static func noiseFreeDeviation(_ p: IdentifyTests.Placement, seed: UInt64, seconds: Double) -> Double {
        let long = p.sampleRate <= 96_000 ? IdentifyTests.longSeconds : p.seconds
        let clean = SignalSynth.make(p.spec, sampleRate: p.sampleRate, seconds: long, snrDb: .infinity,
                                     offsetHz: p.offsetHz, seed: seed)
        let channel = Channel.extract(Array(clean.suffix(2 * Int(seconds * p.sampleRate))), sampleRate: p.sampleRate,
                                      offsetHz: p.offsetHz, bandwidthHz: 1.25 * p.spec.occupiedBandwidthHz)
        let f = FrequencyFeatures.discriminator(channel.samples, rate: channel.rate).dropFirst(64).dropLast(64)
        let mean = f.reduce(0) { $0 + Double($1) } / Double(f.count)
        let excursions = f.map { abs(Double($0) - mean) }.sorted()
        return excursions[Int(0.999 * Double(excursions.count - 1))]
    }

    static func outcome(_ index: Int, snr: Double, seed: UInt64) -> Outcome {
        let p = IdentifyTests.placements[index]
        let id = IdentifyTests.identified(p, snr: snr, seed: seed)
        var o = Outcome(placement: index, snr: snr, seed: seed, identity: id, family: family(p.spec))
        o.rate = rate(p.spec)
        if case .fsk(let f) = p.spec, f.tones == 2 { o.shift = f.spacingHz }
        let wider = id.measurement.notes.contains { $0.contains("wider than the view") }
        switch p.spec {
        case .ssb, .am(.voice, _), .am(.program, _), .fm(.voice, _), .fm(.program, _), .fm(.aptVideo, _),
             .fm(.faxVideo, _):
            if o.familyRight { o.bandwidth = noiseFreeWidth(p, seed: seed, seconds: id.measurement.seconds) }
        case .cw, .carrier:
            if snr >= 20 { o.bandwidth = p.spec.occupiedBandwidthHz }
        default:
            if !wider { o.bandwidth = p.spec.occupiedBandwidthHz }
        }
        // Deviation against the peak the same seed's noise-free capture holds over the read (R17): within 15% for
        // NFM voice (R9), 10% otherwise.
        if o.familyRight, let measured = id.measurement.fmDeviationHz, measured > 0, case .fm(let audio, _) = p.spec {
            switch audio {
            case .voice: o.deviation = (noiseFreeDeviation(p, seed: seed, seconds: id.measurement.seconds), 0.15)
            case .program: o.deviation = (noiseFreeDeviation(p, seed: seed, seconds: id.measurement.seconds), 0.10)
            default: break
            }
        }
        return o
    }

    @Test(.enabled(if: Sweep.full)) func accuracyMatrix() async {
        await Self.check(full: true)
    }

    @Test(.enabled(if: Sweep.full)) func accuracySubset() async {
        await Self.check(full: false)
    }

    /// The full matrix, or the subset.
    static func check(full: Bool) async {
        let clock = ContinuousClock()
        let start = clock.now
        let entries = IdentifyTests.placements.indices.filter { full || IdentifyTests.placements[$0].sampleRate <= 96_000 }
        let seedsPerCell = Self.seedsPerCell(full: full)
        let cases = entries.flatMap { index in
            Self.cellSNRs(full: full).flatMap { snr in
                (0..<seedsPerCell).map { k in (index, snr, UInt64(1 + (seedsPerCell * index + k) % 50)) }
            }
        }
        let outcomes = await withTaskGroup(of: Outcome.self) { group in
            for (index, snr, seed) in cases {
                group.addTask { Self.outcome(index, snr: snr, seed: seed) }
            }
            var all: [Outcome] = []
            for await o in group { all.append(o) }
            return all.sorted { ($0.placement, -$0.snr, $0.seed) < ($1.placement, -$1.snr, $1.seed) }
        }
        let elapsed = clock.now - start
        let summary = Self.summary(outcomes)
        for line in summary.split(separator: "\n") { print(line) }
        // Long test logs can be cut short: SUBFLOOR_SIGNALID_MATRIX_OUT=<path> writes the summary there too.
        if full, let path = ProcessInfo.processInfo.environment["SUBFLOOR_SIGNALID_MATRIX_OUT"] {
            try? summary.write(toFile: path, atomically: true, encoding: .utf8)
        }
        let test = full ? "accuracyMatrix" : "accuracySubset"
        print("\(test): \(outcomes.count) identifications in \(elapsed)")

        for snr in Self.cellSNRs(full: full) {
            let cell = outcomes.filter { $0.snr == snr }
            let wrong = cell.filter(\.wrongName)
            for o in wrong {
                print("\(test) wrong name at \(snr) dB: \(IdentifyTests.placements[o.placement]) seed \(o.seed): "
                      + IdentifyTests.describe(o.identity))
            }
            guard snr >= 10 else { continue }
            let family = Double(cell.filter(\.familyRight).count) / Double(cell.count)
            #expect(family >= 0.95, "family right at \(snr) dB: \(family)")
            let named = Double(cell.filter { $0.named == $0.name }.count) / Double(cell.count)
            #expect(named >= 0.90, "named right at \(snr) dB: \(named)")
            for target in ["rate", "shift", "bandwidth", "deviation"] {
                let judged = cell.flatMap(\.targets).filter { $0.0 == target }
                guard !judged.isEmpty else { continue }
                let met = Double(judged.filter(\.1).count) / Double(judged.count)
                print(String(format: "%@: %@ at %.0f dB: %d of %d (%.1f%%)", test, target, snr,
                             judged.filter(\.1).count, judged.count, 100 * met))
                // The full matrix holds the spec's 95% at the spec's tolerances. The one-seed subset (R23, amended by
                // R24) holds 90% where a target has 10 cases or more; with fewer, a rate can't be judged (at a true
                // 95%, nine cases all pass only 63% of the time), so every case must instead fall within twice the
                // tolerance (shift within 6%), which catches a broken measurement without failing on the spec's 5%.
                if full || judged.count >= 10 {
                    let needed = ((full ? 0.95 : 0.9) * Double(judged.count)).rounded(.up)
                    #expect(Double(judged.filter(\.1).count) >= needed, "\(target) at \(snr) dB: \(met) of \(judged.count)")
                } else {
                    for o in cell {
                        for (name, ok) in o.targets(toleranceScale: 2) where name == target {
                            #expect(ok, "\(target) at \(snr) dB outside twice its tolerance: \(IdentifyTests.placements[o.placement]) seed \(o.seed)")
                        }
                    }
                }
            }
            print(String(format: "%@: at %.0f dB family right %.1f%%, named right %.1f%%", test, snr,
                         100 * family, 100 * named))
        }
        let weak = outcomes.filter { $0.snr == 3 }
        let wrongRate = Double(weak.filter(\.wrongName).count) / Double(weak.count)
        print(String(format: "%@: wrong names at 3 dB: %d of %d (%.1f%%)", test, weak.filter(\.wrongName).count,
                     weak.count, 100 * wrongRate))
        #expect(wrongRate <= 0.02, "wrong names at 3 dB: \(wrongRate)")
    }

    /// One line per catalogue entry and SNR: names given, family, targets met.
    static func summary(_ outcomes: [Outcome]) -> String {
        var lines = ["accuracyMatrix confusion summary (entry | SNR | named | family | targets met)"]
        for index in IdentifyTests.placements.indices {
            let p = IdentifyTests.placements[index]
            for snr in snrs {
                let cell = outcomes.filter { $0.placement == index && $0.snr == snr }
                guard !cell.isEmpty else { continue }
                var names: [String: Int] = [:]
                for o in cell { names[o.named ?? "—", default: 0] += 1 }
                let given = names.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                var families: [String: Int] = [:]
                for o in cell { families[o.identity.measurement.family.rawValue, default: 0] += 1 }
                let family = families.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                var targets: [String: (Int, Int)] = [:]
                for (name, met) in cell.flatMap(\.targets) {
                    targets[name, default: (0, 0)].0 += met ? 1 : 0
                    targets[name, default: (0, 0)].1 += 1
                }
                let met = targets.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.0)/\($0.value.1)" }
                    .joined(separator: ", ")
                lines.append("\(p) | \(Int(snr)) dB | \(given) | \(family) | \(met)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
// MARK: The scenes

/// The spec's added synthetic scenes: neighbours, fading, a comb, level jumps and groups of FT8, the signals in them at
/// 3 dB. A name at 0.7 or more, on the point's answer or on any signal under it, is wrong unless a signal of that mode
/// lies where it was measured. Only with `SUBFLOOR_SIGNALID_MATRIX=1`.
extension AccuracyMatrixTests {
    /// Something in a scene, from the capture's centre: what may be named there (nil: nothing, as on a comb line).
    struct Source: Sendable {
        var offsetHz: Double
        var halfWidthHz: Double
        var name: String?
    }

    /// One scene: the whole capture (the first pass gets its newest `firstSeconds`, the longer read all of it), the points
    /// looked at (offset from the centre, and radius), and what is in it.
    struct Scene {
        var label: String
        var iq: [Float]
        var rate: Double
        var centreHz: Double
        var points: [(offsetHz: Double, radiusHz: Double)]
        var sources: [Source]
        var captureSpectrumDb: [Float]? = nil
        var endTime: Date?
        var firstSeconds = SignalIdentifier.firstSeconds
    }

    enum SceneKind: String, CaseIterable, Sendable { case neighbours, fading, comb, levelJumps, ft8Group }

    static let sceneSNR = 3.0
    static let sceneSeeds = Array(UInt64(1)...8)
    /// How far from where a source lies a measurement may stand and still be that source's.
    static let sceneSlackHz = 50.0
    /// The HF modes the owner listens for, as `IdentifyTests` places them (16 s at 48 kS/s, the pointer as there).
    static let sceneTargets = ["FT8", "FT4", "RTTY", "PSK31 / PSK63", "CW", "SSB voice (USB/LSB)"]
        .map { name in IdentifyTests.placements.first { $0.name == name }! }

    /// `spec` on the slot clock of a capture that starts `startSeconds` after a slot boundary (a slot mode's bursts; any
    /// other spec as it is).
    static func onClock(_ spec: SynthSpec, startSeconds: Double) -> SynthSpec {
        guard case .bursts(let inner, var bursts) = spec else { return spec }
        bursts.captureStartSeconds = startSeconds.truncatingRemainder(dividingBy: bursts.periodSeconds)
        return .bursts(inner, bursts)
    }

    /// Where a 16 s capture starts on the slot clock: as `IdentifyTests.capture` puts a slot mode (its newest 3 s inside
    /// a transmission, at a phase that varies with the seed), by FT8's schedule for the rest.
    static func captureStart(_ spec: SynthSpec, seed: UInt64) -> Double {
        var bursts: SynthSpec.Bursts
        if case .bursts(_, let b) = spec, b.periodSeconds < 60 { bursts = b } else {
            guard case .bursts(_, let b) = SynthSpec.ft8() else { return 0 }
            bursts = b
        }
        let end = bursts.startSeconds + 3.5 + Double(seed % 7) / 7 * (bursts.onSeconds - 3.5)
        return (end - IdentifyTests.longSeconds).truncatingRemainder(dividingBy: bursts.periodSeconds) + bursts.periodSeconds
    }

    static func source(_ spec: SynthSpec, at offsetHz: Double, _ name: String?) -> Source {
        Source(offsetHz: offsetHz, halfWidthHz: spec.occupiedBandwidthHz / 2, name: name)
    }

    /// The scenes of one kind on one seed (each target's, or the FT8 groups).
    static func scenes(_ kind: SceneKind, seed: UInt64) -> [Scene] {
        let seconds = IdentifyTests.longSeconds, snr = sceneSNR
        if kind == .ft8Group { return [ft8Group(seed: seed)] }
        return sceneTargets.map { p -> Scene in
            let start = captureStart(p.spec, seed: seed)
            let spec = onClock(p.spec, startSeconds: start)
            let end = Date(timeIntervalSince1970: SignalSynth.slotEpoch + start + seconds)
            let target = source(spec, at: p.offsetHz, p.name)
            let pointHz = p.offsetHz + p.pointHz
            let label = "\(kind.rawValue) \(p.name) seed \(seed)"
            switch kind {
            case .neighbours:
                // A CW below and an FT8 above, 300 Hz past the target's edges and 15 dB over the noise.
                let cw = SynthSpec.cw(wpm: 20), ft8 = onClock(.ft8(), startSeconds: start)
                let below = p.offsetHz - target.halfWidthHz - 300 - cw.occupiedBandwidthHz / 2
                let above = p.offsetHz + target.halfWidthHz + 300 + ft8.occupiedBandwidthHz / 2
                let iq = SignalSynth.several([.init(spec, offsetHz: p.offsetHz, snrDb: snr, seed: seed),
                                              .init(cw, offsetHz: below, snrDb: 15, seed: seed + 100),
                                              .init(ft8, offsetHz: above, snrDb: 15, seed: seed + 200)],
                                             sampleRate: p.sampleRate, seconds: seconds, noiseSeed: seed + 300)
                return Scene(label: label, iq: iq, rate: p.sampleRate, centreHz: p.captureCenterHz,
                             points: [(pointHz, SignalIdentifier.defaultRadiusHz), (pointHz, 345)],
                             sources: [target, source(cw, at: below, "CW"), source(ft8, at: above, "FT8")], endTime: end)
            case .fading:
                // 20 dB deep at about 0.5 Hz; an FSK's one tone alone on every other seed (selective fading).
                let fsk = spec.keyedFSK != nil && seed % 2 == 0
                let fade = fsk ? SignalSynth.fading(toneIndex: 0, depthDb: 20) : SynthImpairments(fadeDepthDb: 20, fadeRateHz: 0.5)
                let iq = SignalSynth.several([.init(spec, offsetHz: p.offsetHz, snrDb: snr, seed: seed, impairments: fade)],
                                             sampleRate: p.sampleRate, seconds: seconds, noiseSeed: seed + 300)
                return Scene(label: label, iq: iq, rate: p.sampleRate, centreHz: p.captureCenterHz,
                             points: [(pointHz, SignalIdentifier.defaultRadiusHz)], sources: [target], endTime: end)
            case .levelJumps:
                // The receiver's gain 10 dB up (or down, on odd seeds) 1.4 s into the newest 3 s, and 6 dB the other
                // way 6 s into the capture; and an empty point 5 kHz off, through the same jumps.
                let iq = SignalSynth.several([.init(spec, offsetHz: p.offsetHz, snrDb: snr, seed: seed)],
                                             sampleRate: p.sampleRate, seconds: seconds, noiseSeed: seed + 300)
                let sign = seed % 2 == 0 ? 1.0 : -1.0
                let stepped = SignalSynth.levelStep(SignalSynth.levelStep(iq, sampleRate: p.sampleRate, atSeconds: 6,
                                                                          db: -6 * sign),
                                                    sampleRate: p.sampleRate, atSeconds: seconds - 1.6, db: 10 * sign)
                let empty = p.offsetHz + 5000 < p.sampleRate / 2 - 2000 ? p.offsetHz + 5000 : p.offsetHz - 5000
                return Scene(label: label, iq: stepped, rate: p.sampleRate, centreHz: p.captureCenterHz,
                             points: [(pointHz, SignalIdentifier.defaultRadiusHz), (empty, SignalIdentifier.defaultRadiusHz)],
                             sources: [target], endTime: end)
            case .comb:
                // The target between two of the comb's lines (`InterferenceCombTests`' comb, wandering as the owner's
                // does), and two of the lines looked at too: they are never named.
                let rate = InterferenceCombTests.rate
                var iq = SignalSynth.several([.init(spec, offsetHz: p.pointHz == 0 ? 0 : -p.pointHz, snrDb: snr, seed: seed)],
                                             sampleRate: rate, seconds: seconds, noiseSeed: seed + 300)
                let comb = SignalSynth.comb(firstHz: InterferenceCombTests.firstHz, spacingHz: InterferenceCombTests.spacingHz,
                                            count: InterferenceCombTests.lines,
                                            amplitude: TraceFinderTests.amplitude(db: 25, rate: rate), sampleRate: rate,
                                            seconds: seconds, wanderHz: 60, seed: seed + 400)
                for k in iq.indices { iq[k] += comb[k] }
                let lines = (0..<InterferenceCombTests.lines).map {
                    Source(offsetHz: InterferenceCombTests.lineHz($0), halfWidthHz: 150, name: nil)
                }
                let centred = source(spec, at: p.pointHz == 0 ? 0 : -p.pointHz, p.name)
                return Scene(label: label, iq: iq, rate: rate, centreHz: p.rfHz,
                             points: [(0, SignalIdentifier.defaultRadiusHz),
                                      (InterferenceCombTests.lineHz(4), SignalIdentifier.defaultRadiusHz),
                                      (InterferenceCombTests.lineHz(7), SignalIdentifier.defaultRadiusHz)],
                             sources: [centred] + lines,
                             captureSpectrumDb: InterferenceCombTests.spectrum(iq, rate: rate), endTime: end)
            case .ft8Group:
                fatalError("made above")
            }
        }
    }

    /// Seven FT8 stations 250 Hz apart (as `GroupAnswerTests` makes them: the slot's first 3 s, every other one 0.2 s
    /// late), and on odd seeds a PSK31 keying up between two of them: looked at from the group's middle at the owner's
    /// zoom (345 Hz) and wider (700 Hz), and on one station.
    static func ft8Group(seed: UInt64) -> Scene {
        let rate = GroupAnswerTests.rate, seconds = GroupAnswerTests.seconds
        var placed: [SignalSynth.Placed] = (0..<7).map { (k: Int) -> SignalSynth.Placed in
            let late: Double = k % 2 == 0 ? 0 : 0.2
            return GroupAnswerTests.ft8(Double(k - 3) * 250, snrDb: sceneSNR, seed: 1000 * seed + UInt64(k), lateSeconds: late)
        }
        var sources = placed.map { source($0.spec, at: $0.offsetHz, "FT8") }
        if seed % 2 == 1 {
            let psk = SignalSynth.Placed(.psk31, offsetHz: 125, snrDb: sceneSNR, seed: 1000 * seed + 50)
            placed.append(psk)
            sources.append(source(.psk31, at: 125, "PSK31 / PSK63"))
        }
        let iq = SignalSynth.several(placed, sampleRate: rate, seconds: seconds, noiseSeed: 1000 * seed + 99)
        // The on-time stations' clock: their capture starts on a slot boundary.
        let end = Date(timeIntervalSince1970: SignalSynth.slotEpoch + 15 + seconds)
        return Scene(label: "ft8Group seed \(seed)", iq: iq, rate: rate, centreHz: GroupAnswerTests.centreHz,
                     points: [(0, RealCorpus.groupRadiusHz), (0, 700), (250, SignalIdentifier.defaultRadiusHz)],
                     sources: sources, endTime: end, firstSeconds: seconds)
    }

    /// What the scene's points answer, as the hover's refining call (the longer read is the whole capture), and the wrong
    /// names among them (the point's answer and every signal under it).
    static func judged(_ scene: Scene) -> (answers: [SignalIdentity], wrong: [String]) {
        let seconds = Double(scene.iq.count / 2) / scene.rate
        let first = Array(scene.iq.suffix(2 * Int((scene.firstSeconds * scene.rate).rounded())))
        var answers: [SignalIdentity] = [], wrong: [String] = []
        for point in scene.points {
            let id = SignalIdentifier.identify(iq: first, sampleRate: scene.rate, captureCenterHz: scene.centreHz,
                                               atHz: scene.centreHz + point.offsetHz, bandwidthHz: nil, spectrumDb: nil,
                                               longer: { (scene.iq, seconds) }, pointRadiusHz: point.radiusHz,
                                               endTime: scene.endTime, captureSpectrumDb: scene.captureSpectrumDb,
                                               captureRate: scene.captureSpectrumDb == nil ? nil : scene.rate)
            answers.append(id)
            for answer in [id] + id.signals {
                guard let best = answer.best, best.confidence >= SignalIdentifier.nameThreshold else { continue }
                let hz = answer.measurement.offsetHz
                let there = scene.sources.contains {
                    $0.name == best.name && abs(hz - $0.offsetHz) <= $0.halfWidthHz + sceneSlackHz
                }
                if !there {
                    wrong.append(String(format: "%@, point %+.0f Hz r %.0f: %@ at %+.0f Hz (%@)", scene.label,
                                        point.offsetHz, point.radiusHz, best.name, hz, id.label))
                }
            }
        }
        return (answers, wrong)
    }

    /// Every scene, every signal in it at 3 dB: no wrong name. Prints how often the point's own signal was named.
    @Test(.enabled(if: Sweep.full)) func scenesHaveNoWrongNames() async {
        let cases = SceneKind.allCases.flatMap { kind in Self.sceneSeeds.map { (kind, $0) } }
        typealias Result = (kind: SceneKind, answers: Int, named: Int, wrong: [String])
        let results = await withTaskGroup(of: Result.self) { group in
            for (kind, seed) in cases {
                group.addTask {
                    var points = 0, named = 0, wrong: [String] = []
                    for scene in Self.scenes(kind, seed: seed) {
                        let judged = Self.judged(scene)
                        points += judged.answers.count
                        wrong += judged.wrong
                        // The first point is on a signal: named as it is.
                        if let own = judged.answers.first, let name = own.best?.name,
                           scene.sources.contains(where: { $0.name == name }) { named += 1 }
                    }
                    return (kind, points, named, wrong)
                }
            }
            var all: [Result] = []
            for await r in group { all.append(r) }
            return all
        }
        for kind in SceneKind.allCases {
            let mine = results.filter { $0.kind == kind }
            let wrong = mine.flatMap { $0.wrong }
            let scenes = kind == .ft8Group ? Self.sceneSeeds.count : Self.sceneSeeds.count * Self.sceneTargets.count
            let answers = mine.map { $0.answers }.reduce(0, +), named = mine.map { $0.named }.reduce(0, +)
            print("scenesHaveNoWrongNames \(kind.rawValue): \(scenes) scenes, \(answers) answers, "
                  + "first point named \(named) of \(scenes), wrong names \(wrong.count)")
            for line in wrong { print("scenesHaveNoWrongNames wrong: \(line)") }
            #expect(wrong.isEmpty, "\(kind.rawValue) at \(Self.sceneSNR) dB: \(wrong)")
        }
    }
}
