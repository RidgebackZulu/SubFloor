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
