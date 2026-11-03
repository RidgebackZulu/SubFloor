import Foundation
import Testing
@testable import SignalID

/// A narrow MFSK read symbol by symbol (`SymbolTones`), and what isn't one.
@Suite(.serialized) struct SymbolTonesTests {
    static let rate = 12_000.0

    /// `spec` at `snr`, `seconds` of it from inside a transmission when it is a slot mode's, at 1 kHz.
    static func iq(_ spec: SynthSpec, seconds: Double, snr: Double, seed: UInt64) -> [Float] {
        var placed = spec
        if case .bursts(let inner, var bursts) = spec {
            bursts.captureStartSeconds = bursts.startSeconds + 0.1
            placed = .bursts(inner, bursts)
        }
        return SignalSynth.make(placed, sampleRate: rate, seconds: seconds, snrDb: snr, offsetHz: 1000, seed: seed)
    }

    /// FT8 over 3 s and 12 s and FT4 over 4.5 s, at 10 and 4 dB (4 dB alone, 12 s with the matrix, by default): their
    /// speed within 1%, their tones within 5% of it, their tone count exact.
    @Test(arguments: Sweep.full ? Array(UInt64(1)...6) : [1])
    func readsFT8AndFT4(seed: UInt64) throws {
        let cases = [(SynthSpec.ft8(), 3.0, 60.0, 8, 6.25), (.ft4(), 4.5, 100, 4, 12_000 / 576.0)]
            + (Sweep.full ? [(.ft8(), 12, 60, 8, 6.25)] : [])
        for (spec, seconds, width, tones, baud) in cases {
            for snr in Sweep.full ? [10.0, 4] : [4] {
                let read = try #require(SymbolTones.read(Self.iq(spec, seconds: seconds, snr: snr, seed: seed),
                                                         sampleRate: Self.rate, offsetHz: 1000, widthHz: width),
                                        "\(tones) tones, \(seconds) s, \(snr) dB")
                #expect(abs(read.baud / baud - 1) <= 0.01, "\(seconds) s at \(snr) dB: \(read)")
                // The tones' own spacing reads a little narrow (Gaussian keying); within the slot rows' 5%.
                #expect(abs(read.tonesSpacingHz / baud - 1) <= 0.05, "\(seconds) s at \(snr) dB: \(read)")
                #expect(read.toneCount == tones, "\(read)")
                #expect(abs(read.centreHz) <= read.spacingHz / 2, "\(read)")
            }
        }
    }

    /// One frequency isn't an MFSK, however it is keyed: a PSK31, a CW key, a line that pulses 30 times a second (an
    /// interference comb's), a carrier, or noise.
    @Test func oneFrequencyIsNoMFSK() {
        let pulses = SynthSpec.bursts(.carrier, .init(periodSeconds: 1 / 30.0, onSeconds: 0.01))
        let cases: [(String, SynthSpec)] = [("PSK31", .psk(.init(order: 2, rate: 31.25, shape: .cosine))),
                                            ("CW", .cw(wpm: 20)), ("pulses", pulses), ("carrier", .carrier),
                                            ("noise", .noise)]
        for (name, spec) in cases {
            for seed in Sweep.full ? Array(UInt64(1)...6) : [1] {
                let read = SymbolTones.read(Self.iq(spec, seconds: 4, snr: 15, seed: seed), sampleRate: Self.rate,
                                            offsetHz: 1000, widthHz: 80)
                #expect(read == nil, "\(name) seed \(seed): \(String(describing: read))")
            }
        }
    }

    /// A narrow trace whose symbols hop between tones isn't a PSK, whatever the measurer made of its few seconds.
    @Test func hoppingTonesAreNotPSK() throws {
        let iq = Self.iq(.ft8(), seconds: 3, snr: 10, seed: 3)
        let map = SignalIdentifier.neighbourhoodMap(iq, sampleRate: Self.rate, pointHz: 1000)
        let trace = try #require(SignalIdentifier.pointTrace(TraceFinder.find(map), pointHz: 1000, radiusHz: 60))
        let psk = SignalMeasurement(offsetHz: 1000, occupiedBandwidthHz: 50, family: .psk, familyConfidence: 0.9,
                                    symbolRate: 31.25, pskOrder: 2, seconds: 3)
        let read = try #require(SignalIdentifier.symbolReading(iq, sampleRate: Self.rate, trace: trace, pointHz: 1000,
                                                               map: map, on: [0...3], seconds: 3, measured: psk))
        #expect(read.family == .fsk && read.toneCount == 8, "\(read)")
        #expect(read.notes.contains("Its symbols hop between tones: not PSK"))
        // A carrier line is no MFSK: it isn't read.
        var keyed = psk
        keyed.family = .ook
        #expect(SignalIdentifier.symbolReading(iq, sampleRate: Self.rate, trace: trace, pointHz: 1000, map: map,
                                               on: [0...3], seconds: 3, measured: keyed) == nil)
    }
}

// MARK: Each check, and the reader through identify

extension SymbolTonesTests {
    /// `spec` at 1 kHz, as `iq` places it but from the capture's start for a schedule of a second or less.
    static func at(_ spec: SynthSpec, seconds: Double, snr: Double, seed: UInt64, offsetHz: Double = 1000) -> [Float] {
        var placed = spec
        if case .bursts(let inner, var bursts) = spec, bursts.periodSeconds > 1 {
            bursts.captureStartSeconds = bursts.startSeconds + 0.1
            placed = .bursts(inner, bursts)
        }
        return SignalSynth.make(placed, sampleRate: rate, seconds: seconds, snrDb: snr, offsetHz: offsetHz, seed: seed)
    }

    /// The smallest case each check alone stops (found over 27 kinds of signal, 3 and 12 s, 3–25 dB, seeds 1–4): it
    /// isn't read, and is read with that check left out.
    @Test func eachCheckStopsWhatOnlyItCan() {
        let cw = SynthSpec.cw(wpm: 20)
        let fsk85 = SynthSpec.fsk(.init(tones: 2, rate: 45.45, spacingHz: 85))
        let pulses = SynthSpec.bursts(.carrier, .init(periodSeconds: 0.16, onSeconds: 0.08))
        let slowMFSK = SynthSpec.fsk(.init(tones: 8, rate: 3.125, spacingHz: 3.125, gaussianBT: 2))
        let twoKeys = { (seconds: Double, snr: Double, seed: UInt64) -> [Float] in
            zip(Self.at(cw, seconds: seconds, snr: snr, seed: seed, offsetHz: 980),
                Self.at(.cw(wpm: 25), seconds: seconds, snr: snr, seed: seed + 100, offsetHz: 1020)).map { $0 + $1 }
        }
        let cases: [(SymbolTones.Check, String, [Float], Double)] = [
            (.contrast, "a CW key", Self.at(cw, seconds: 3, snr: 10, seed: 2), 60),
            (.spanFill, "two CW keys 40 Hz apart", twoKeys(3, 10, 2), 100),
            (.emptyTone, "a 2-FSK 85 Hz wide", Self.at(fsk85, seconds: 3, snr: 3, seed: 1), 150),
            (.exclusivity, "a 2-FSK 85 Hz wide", Self.at(fsk85, seconds: 12, snr: 3, seed: 1), 150),
            (.toneShare, "a line pulsing at FT8's rate", Self.at(pulses, seconds: 3, snr: 25, seed: 3), 60),
            (.pairs, "an 8-FSK at 3.125 Bd read at twice it", Self.at(slowMFSK, seconds: 3, snr: 10, seed: 4), 40),
        ]
        #expect(Set(cases.map(\.0)) == Set(SymbolTones.Check.allCases))
        for (check, name, iq, width) in cases {
            let read = SymbolTones.read(iq, sampleRate: Self.rate, offsetHz: 1000, widthHz: width)
            #expect(read == nil, "\(check): \(name) read as \(String(describing: read))")
            let without = SymbolTones.read(iq, sampleRate: Self.rate, offsetHz: 1000, widthHz: width,
                                           checks: Set(SymbolTones.Check.allCases).subtracting([check]))
            #expect(without != nil, "\(check) isn't what stops \(name)")
        }
    }

    /// The tuning part's interference comb (14077955 Hz, 15 s): its lines are all there at once, a symbol of its pulses
    /// apart, and read as a 4-tone MFSK named Olivia but for the one-tone-at-a-time check. With the matrix (the check is
    /// held by `eachCheckStopsWhatOnlyItCan` by default).
    @Test(.enabled(if: Sweep.full)) func theCorpusCombIsNoMFSK() throws {
        let point = try #require(try RealCorpus.points(.tuning).first {
            $0.truth == "comb" && $0.atHz == 14_077_955 && $0.endSeconds == 15
        })
        let clip = try #require(try RealCorpus.clips().first { $0.name == point.clip })
        let id = RealCorpus.hover(clip, point)
        #expect(!RealCorpus.isWrongName(id, point) && id.measurement.family != .fsk, "\(IdentifyTests.describe(id))")
    }

    static let captureRate = SlotEvidenceTests.rate
    static func identify(_ iq: [Float], at rfHz: Double, longer: [Float]? = nil, seconds: Double = 0) -> SignalIdentity {
        SignalIdentifier.identify(iq: iq, sampleRate: captureRate, captureCenterHz: rfHz - SlotEvidenceTests.offsetHz,
                                  atHz: rfHz, bandwidthHz: nil, spectrumDb: nil,
                                  longer: longer.map { long in { (long, seconds) } })
    }

    /// An FT8 the measurer takes for a PSK on 3 s (2.5 s into its transmission) is renamed on the quick answer: its tones
    /// hop.
    @Test func hoppingTonesMeasuredPSKAreRenamedOnTheQuickAnswer() {
        let capture = SlotEvidenceTests.capture(.ft8(), readSeconds: 3, endInTransmission: 2.5, rfHz: 14_075_500, seed: 12)
        let id = Self.identify(capture.first, at: 14_075_500)
        #expect(id.best?.name == "FT8", "\(IdentifyTests.describe(id))")
        #expect(id.measurement.notes.contains("Its symbols hop between tones: not PSK"), "\(IdentifyTests.describe(id))")
    }

    /// Two FT8 stations 70 Hz apart, one trace on the map: the one at the point is read on its own side of the dip
    /// between them, not as one 16-tone MFSK.
    @Test func twoFT8StationsSideBySideAreReadOneByOne() {
        guard case .bursts(let inner, var bursts) = SynthSpec.ft8() else { return }
        bursts.captureStartSeconds = (bursts.startSeconds + 11 - 12).truncatingRemainder(dividingBy: 15) + 15
        var later = bursts
        later.captureStartSeconds += 0.2
        let point = SignalSynth.make(.bursts(inner, bursts), sampleRate: Self.captureRate, seconds: 12, snrDb: 10,
                                     offsetHz: SlotEvidenceTests.offsetHz, seed: 2)
        let beside = SignalSynth.render(.bursts(inner, later), sampleRate: Self.captureRate, seconds: 12,
                                        offsetHz: SlotEvidenceTests.offsetHz + 70, seed: 79)
        let long = zip(point, beside).map { $0 + 0.9 * $1 }
        let id = Self.identify(Array(long.suffix(2 * Int(3 * Self.captureRate))), at: 14_075_500, longer: long, seconds: 12)
        #expect(id.best?.name == "FT8" && abs(id.measurement.offsetHz - SlotEvidenceTests.offsetHz) < 5,
                "\(IdentifyTests.describe(id))")
    }

    /// The longer read's longest transmission at the point is a PSK31 burst before the FT8 the first pass read: the first
    /// pass's tones stand.
    @Test func theFirstPassesTonesStand() {
        let capture = SlotEvidenceTests.capture(.ft8(), readSeconds: 12, endInTransmission: 3, rfHz: 14_075_500, seed: 1)
        var psk = SignalSynth.make(.psk(.init(order: 2, rate: 31.25, shape: .cosine)), sampleRate: Self.captureRate,
                                   seconds: 12, snrDb: .infinity, offsetHz: SlotEvidenceTests.offsetHz, seed: 41)
        for k in (2 * Int(6.5 * Self.captureRate))..<psk.count { psk[k] = 0 }
        let long = zip(capture.long, psk).map { $0 + 2 * $1 }
        let id = Self.identify(Array(long.suffix(2 * Int(3 * Self.captureRate))), at: 14_075_500, longer: long, seconds: 12)
        #expect(id.best?.name == "FT8", "\(IdentifyTests.describe(id))")
    }

    /// A narrow trace nothing names on the quick answer (FT8 at 6 dB, off its frequencies) asks for the longer read.
    @Test func aNarrowUnknownTraceAsksForTheLongerRead() {
        guard case .bursts(let inner, var bursts) = SynthSpec.ft8() else { return }
        bursts.captureStartSeconds = 3.5
        let iq = SignalSynth.make(.bursts(inner, bursts), sampleRate: Self.captureRate, seconds: 3, snrDb: 6,
                                  offsetHz: SlotEvidenceTests.offsetHz, seed: 1)
        let id = Self.identify(iq, at: 14_200_000)
        #expect(id.best == nil && id.measurement.family == .unknown && id.needsLongerRead, "\(IdentifyTests.describe(id))")
    }
}

extension SymbolTonesTests {
    /// Tones 8% wider than the rate (rectangular keying, which doesn't pull them together) are given as they read; within
    /// 5% the rate stands for them (Gaussian keying pulls FT4's in by 2–5%).
    @Test func aSpacingOffTheRateIsGivenAsRead() throws {
        let wide = SynthSpec.fsk(.init(tones: 4, rate: 20, spacingHz: 21.6))
        let read = try #require(SymbolTones.read(Self.at(wide, seconds: 4.5, snr: 15, seed: 1), sampleRate: Self.rate,
                                                 offsetHz: 1000, widthHz: 110))
        #expect(abs(read.baud / 20 - 1) < 0.01 && abs(read.spacingHz / 21.6 - 1) < 0.03, "\(read)")
        let ft4 = try #require(SymbolTones.read(Self.iq(.ft4(), seconds: 4.5, snr: 15, seed: 1), sampleRate: Self.rate,
                                                offsetHz: 1000, widthHz: 100))
        #expect(ft4.spacingHz == ft4.baud, "\(ft4)")
    }
}
