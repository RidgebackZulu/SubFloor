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
/// The full matrix (every SNR, 5 seeds a cell) runs with `SUBFLOOR_SIGNALID_MATRIX=1`; otherwise the always-on
/// subset (ruling R20): 10 and 3 dB, one seed a cell, the captures of 96 kS/s or less (20 dB naming, WFM's and
/// DAB's included, is `IdentifyTests.eachRowIsNamed`'s). Its targets may fall two cases short of 95% (one-seed
/// cells); the full matrix's may not.
@Suite struct AccuracyMatrixTests {
    static let snrs = [20.0, 10, 6, 3]
    /// `SUBFLOOR_SIGNALID_MATRIX=1`: the full matrix. Otherwise the always-on subset (ruling R20).
    static var full: Bool { ProcessInfo.processInfo.environment["SUBFLOOR_SIGNALID_MATRIX"] == "1" }
    static var seedsPerCell: Int { full ? 5 : 1 }
    static var cellSNRs: [Double] { full ? snrs : [10, 3] }

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
        var targets: [(String, Bool)] {
            guard familyRight else { return [] }
            let m = identity.measurement
            var out: [(String, Bool)] = []
            if let rate { out.append(("rate", Self.within(m.symbolRate, rate, 0.01))) }
            if let shift { out.append(("shift", Self.within(m.fskShiftHz, shift, 0.03))) }
            if let bandwidth { out.append(("bandwidth", Self.within(m.occupiedBandwidthHz, bandwidth, 0.10))) }
            if let deviation { out.append(("deviation", Self.within(m.fmDeviationHz, deviation.value, deviation.tolerance))) }
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

    @Test func accuracyMatrix() async {
        let clock = ContinuousClock()
        let start = clock.now
        let entries = IdentifyTests.placements.indices.filter { Self.full || IdentifyTests.placements[$0].sampleRate <= 96_000 }
        let cases = entries.flatMap { index in
            Self.cellSNRs.flatMap { snr in
                (0..<Self.seedsPerCell).map { k in (index, snr, UInt64(1 + (Self.seedsPerCell * index + k) % 50)) }
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
        if let path = ProcessInfo.processInfo.environment["SUBFLOOR_SIGNALID_MATRIX_OUT"] {
            try? summary.write(toFile: path, atomically: true, encoding: .utf8)
        }
        print("accuracyMatrix: \(outcomes.count) identifications in \(elapsed)")

        for snr in Self.cellSNRs {
            let cell = outcomes.filter { $0.snr == snr }
            let wrong = cell.filter(\.wrongName)
            for o in wrong {
                print("accuracyMatrix wrong name at \(snr) dB: \(IdentifyTests.placements[o.placement]) seed \(o.seed): "
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
                print(String(format: "accuracyMatrix: %@ at %.0f dB: %d of %d (%.1f%%)", target, snr,
                             judged.filter(\.1).count, judged.count, 100 * met))
                // The subset's cells are one seed: it may fall two cases short of 95% (the full matrix may not).
                let needed = (0.95 * Double(judged.count)).rounded(.up) - (Self.full ? 0 : 2)
                #expect(Double(judged.filter(\.1).count) >= needed, "\(target) at \(snr) dB: \(met) of \(judged.count)")
            }
            print(String(format: "accuracyMatrix: at %.0f dB family right %.1f%%, named right %.1f%%", snr,
                         100 * family, 100 * named))
        }
        let weak = outcomes.filter { $0.snr == 3 }
        let wrongRate = Double(weak.filter(\.wrongName).count) / Double(weak.count)
        print(String(format: "accuracyMatrix: wrong names at 3 dB: %d of %d (%.1f%%)", weak.filter(\.wrongName).count,
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
