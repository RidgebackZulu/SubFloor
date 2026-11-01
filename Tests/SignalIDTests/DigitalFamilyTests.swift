import Accelerate
import DSPCore
import Foundation
import Testing
@testable import SignalID

/// Task 4's families through `SignalMeasurer.measure`: FSK, MFSK, PSK, OFDM, bursts and subcarriers, each
/// synthesised at 20 and 10 dB and seeded the way the app seeds it (the extent `Extent.find` gives where the
/// pointer rests). Seeds 1–50 only (thresholds were tuned on seeds ≥ 1000).
@Suite struct DigitalFamilyTests {
    /// Synthesises `spec` centred on `offsetHz`, seeds the measurement with the extent found with the pointer
    /// `pointHz` from the centre (a wide-shift FSK's centre is empty: the pointer rests on one tone) and
    /// measures it.
    static func measured(_ spec: SynthSpec, sampleRate fs: Double = 48_000, snr: Double, seed: UInt64,
                         offsetHz: Double = 3000, pointHz: Double = 0, seconds: Double = 3,
                         fftSize: Int = 4096) -> SignalMeasurement {
        let iq = SignalSynth.make(spec, sampleRate: fs, seconds: seconds, snrDb: snr, offsetHz: offsetHz, seed: seed)
        let binHz = fs / Double(fftSize)
        let db = PowerSpectrum.average(iq, size: fftSize)
        let near = fftSize / 2 + Int(((offsetHz + pointHz) / binHz).rounded())
        guard let extent = Extent.find(spectrumDb: db, binHz: binHz, nearBin: near, searchBins: 4) else {
            Issue.record("\(spec) at \(snr) dB, seed \(seed): no extent")
            return SignalMeasurement()
        }
        let width = Double(extent.upperBin - extent.lowerBin + 1) * binHz
        let centre = (Double(extent.lowerBin + extent.upperBin) / 2 - Double(fftSize / 2)) * binHz
        return SignalMeasurer.measure(iq, sampleRate: fs, offsetHz: centre, bandwidthHz: width, seconds: seconds)
    }

    static func within(_ value: Double?, _ truth: Double, _ tolerance: Double) -> Bool {
        guard let value else { return false }
        return abs(value / truth - 1) <= tolerance
    }

    /// Two subcarrier tones: their shift within 3% (as an FSK's) and their middle within 1% of the shift.
    static func tonePair(_ tones: [Double], centre: Double, shift: Double) -> Bool {
        guard tones.count == 2 else { return false }
        return within(tones[1] - tones[0], shift, 0.03) && abs((tones[0] + tones[1]) / 2 - centre) <= 0.01 * shift
    }

    /// One FSK case: tones, symbol rate and tone spacing (the shift, for 2-FSK).
    struct FSKCase: Sendable, CustomStringConvertible {
        var name: String
        var spec: SynthSpec
        var sampleRate = 48_000.0
        var pointHz = 0.0
        var family = SignalFamily.fsk
        var tones: Int
        var rate: Double
        var spacing: Double
        var description: String { name }
    }

    static let fskCases: [FSKCase] = [
        FSKCase(name: "RTTY 45.45/170", spec: .rtty(baud: 45.45, shiftHz: 170), tones: 2, rate: 45.45, spacing: 170),
        FSKCase(name: "RTTY 50/850", spec: .rtty(baud: 50, shiftHz: 850), pointHz: 425, tones: 2, rate: 50,
                spacing: 850),
        FSKCase(name: "RTTY 75/425", spec: .rtty(baud: 75, shiftHz: 425), pointHz: -212.5, tones: 2, rate: 75,
                spacing: 425),
        FSKCase(name: "SITOR-B 100/170", spec: .navtex, tones: 2, rate: 100, spacing: 170),
        FSKCase(name: "POCSAG 1200 ±4.5 kHz", spec: .pocsag(baud: 1200), pointHz: 4500, tones: 2, rate: 1200,
                spacing: 9000),
        FSKCase(name: "4-FSK 4800 (P25)", spec: .p25, tones: 4, rate: 4800, spacing: 1200),
        FSKCase(name: "8-FSK 125 Bd 250 Hz (ALE)", spec: .ale, tones: 8, rate: 125, spacing: 250),
        FSKCase(name: "Olivia 32/1000", spec: .olivia(tones: 32, bandwidthHz: 1000), family: .mfsk, tones: 32,
                rate: 31.25, spacing: 31.25),
        FSKCase(name: "MFSK16", spec: .mfsk16, family: .mfsk, tones: 16, rate: 15.625, spacing: 15.625),
        FSKCase(name: "GMSK 9600", spec: .gmsk(rate: 9600, bt: 0.4), sampleRate: 96_000, tones: 2, rate: 9600,
                spacing: 4800),
    ]

    @Test(arguments: [20.0, 10.0])
    func fskTonesRateAndShift(snr: Double) {
        for (index, c) in Self.fskCases.enumerated() {
            for seed in UInt64(1)...2 {
                let m = Self.measured(c.spec, sampleRate: c.sampleRate, snr: snr, seed: UInt64(3 * index) + seed,
                                      pointHz: c.pointHz)
                let label = "\(c) at \(snr) dB, seed \(seed)"
                #expect(m.family == c.family, "\(label): \(m.family) \(m.familyConfidence) \(m.notes)")
                #expect(m.toneCount == c.tones, "\(label): \(m.toneCount ?? -1) tones")
                #expect(Self.within(m.symbolRate, c.rate, 0.01), "\(label): \(m.symbolRate ?? -1) Bd")
                #expect(Self.within(m.toneSpacingHz, c.spacing, 0.03), "\(label): spacing \(m.toneSpacingHz ?? -1)")
                if c.tones == 2 {
                    #expect(Self.within(m.fskShiftHz, c.spacing, 0.03), "\(label): shift \(m.fskShiftHz ?? -1)")
                }
                #expect(m.envelope == .steady, "\(label): \(m.envelope)")
            }
        }
    }

    /// DMR's 4-FSK 4800 in 27.5 ms bursts every 60 ms (one 30 ms TDMA slot in use): the same 4-FSK, plus the
    /// burst period and duty. SNR is the mean over the capture (ruling R6).
    @Test(arguments: [20.0, 10.0])
    func fourFSKInTDMABursts(snr: Double) {
        for seed in UInt64(31)...33 {
            let m = Self.measured(.dmr, snr: snr, seed: seed)
            let label = "DMR at \(snr) dB, seed \(seed)"
            #expect(m.family == .fsk, "\(label): \(m.family) \(m.notes)")
            #expect(m.envelope == .bursty, "\(label): \(m.envelope)")
            #expect(m.toneCount == 4, "\(label): \(m.toneCount ?? -1) tones")
            #expect(Self.within(m.symbolRate, 4800, 0.01), "\(label): \(m.symbolRate ?? -1) Bd")
            #expect(Self.within(m.toneSpacingHz, 1296, 0.03), "\(label): spacing \(m.toneSpacingHz ?? -1)")
            #expect(Self.within(m.burstPeriodSeconds, 0.06, 0.02), "\(label): period \(m.burstPeriodSeconds ?? -1)")
            #expect(abs((m.burstDuty ?? -1) - 0.0275 / 0.06) <= 0.05, "\(label): duty \(m.burstDuty ?? -1)")
            #expect(abs(m.snrDb - snr) <= 1.5, "\(label): SNR \(m.snrDb)")
        }
    }

    @Test(arguments: [20.0, 10.0])
    func pskOrderAndRate(snr: Double) {
        let cases: [(String, SynthSpec, Int, Double)] = [
            ("BPSK31", .psk31, 2, 31.25),
            ("QPSK31", .qpsk31, 4, 31.25),
            ("BPSK 1800", .psk(.init(order: 2, rate: 1800)), 2, 1800),
            ("8PSK 2400", .stanag4285, 8, 2400),
        ]
        for (index, (name, spec, order, rate)) in cases.enumerated() {
            for seed in UInt64(1)...2 {
                let m = Self.measured(spec, snr: snr, seed: UInt64(10 + 3 * index) + seed)
                let label = "\(name) at \(snr) dB, seed \(seed)"
                #expect(m.family == .psk, "\(label): \(m.family) \(m.familyConfidence) \(m.notes)")
                #expect(m.pskOrder == order, "\(label): order \(m.pskOrder ?? -1)")
                #expect(Self.within(m.symbolRate, rate, 0.01), "\(label): \(m.symbolRate ?? -1) Bd")
            }
        }
    }

    /// DRM-like OFDM (mode A, 41.67 Hz; mode B, 46.875 Hz; about 10 kHz) at 48 kS/s.
    @Test(arguments: [20.0, 10.0])
    func drmLikeOFDMSpacing(snr: Double) {
        for (index, (spec, spacing)) in [(SynthSpec.drmModeA, 1000 / 24.0), (.drm, 46.875)].enumerated() {
            for seed in UInt64(1)...2 {
                let m = Self.measured(spec, snr: snr, seed: UInt64(36 + 2 * index) + seed, offsetHz: 6000)
                let label = "DRM \(spacing) Hz at \(snr) dB, seed \(seed)"
                #expect(m.family == .ofdm, "\(label): \(m.family) \(m.notes)")
                #expect(Self.within(m.ofdmSpacingHz, spacing, 0.02), "\(label): \(m.ofdmSpacingHz ?? -1) Hz")
                #expect(Self.within(m.occupiedBandwidthHz, spec.occupiedBandwidthHz, 0.10),
                        "\(label): \(m.occupiedBandwidthHz) Hz of \(spec.occupiedBandwidthHz)")
            }
        }
    }

    /// DAB-like OFDM: 1536 carriers at 1 kHz (1.536 MHz) in a 2.048 MS/s capture.
    @Test(arguments: [20.0, 10.0])
    func dabLikeOFDMSpacing(snr: Double) {
        let m = Self.measured(.dab, sampleRate: 2_048_000, snr: snr, seed: 44, offsetHz: 0, seconds: 1,
                              fftSize: 2048)
        #expect(m.family == .ofdm, "\(m.family) \(m.notes)")
        #expect(Self.within(m.ofdmSpacingHz, 1000, 0.02), "\(m.ofdmSpacingHz ?? -1) Hz")
        #expect(!m.notes.contains { $0.contains("wider than the view") }, "\(m.notes)")
    }

    /// A mode wider than the capture is named by family only, with a note (ruling R5): DAB cut to 1.024 MS/s.
    @Test func ofdmWiderThanTheViewIsFamilyOnly() {
        let wide = SignalSynth.make(.dab, sampleRate: 2_048_000, seconds: 1, snrDb: 20, seed: 45)
        // Low-passed to ±450 kHz, then every other sample: a 1.024 MS/s capture.
        let filtered = Channel.extract(wide, sampleRate: 2_048_000, offsetHz: 0, bandwidthHz: 900_000)
        let halved = stride(from: 0, to: filtered.samples.count, by: 2).map { filtered.samples[$0] }
        let rate = filtered.rate / 2
        #expect(rate < 1_536_000)
        let iq = SignalMeasurer.interleaved(halved)
        let m = SignalMeasurer.measure(iq, sampleRate: rate, offsetHz: 0, bandwidthHz: 0.8 * rate, seconds: 1)
        #expect(m.family == .ofdm, "\(m.family) \(m.notes)")
        #expect(m.notes.contains { $0.contains("wider than the view") }, "\(m.notes)")
        #expect(m.ofdmSpacingHz == nil)
    }

    /// APRS: NFM carrying Bell 202 AFSK (1200 Bd, 1200/2200 Hz). The carrier is FM; the AFSK is a subcarrier.
    @Test(arguments: [20.0, 10.0])
    func afskInsideNFM(snr: Double) {
        for seed in UInt64(1)...2 {
            let m = Self.measured(.aprs, snr: snr, seed: 45 + seed, offsetHz: 6000)
            let label = "APRS at \(snr) dB, seed \(seed)"
            #expect(m.family == .fm, "\(label): \(m.family) \(m.notes)")
            #expect(Self.tonePair(m.subcarriersHz, centre: 1700, shift: 1000), "\(label): \(m.subcarriersHz)")
            #expect(Self.within(m.symbolRate, 1200, 0.01), "\(label): \(m.symbolRate ?? -1) Bd")
        }
    }

    /// ACARS: AM carrying 2400 Bd MSK audio (1200/2400 Hz). Still AM, with the MSK as a subcarrier.
    @Test(arguments: [20.0, 10.0])
    func mskInsideAM(snr: Double) {
        for seed in UInt64(1)...2 {
            let m = Self.measured(.acars, snr: snr, seed: 47 + seed, offsetHz: 6000)
            let label = "ACARS at \(snr) dB, seed \(seed)"
            #expect(m.family == .am, "\(label): \(m.family) \(m.notes)")
            #expect(Self.tonePair(m.subcarriersHz, centre: 1800, shift: 1200), "\(label): \(m.subcarriersHz)")
        }
    }

    /// NOAA APT: FM carrying the 2400 Hz AM subcarrier.
    @Test(arguments: [20.0, 10.0])
    func aptSubcarrier(snr: Double) {
        for seed in UInt64(1)...2 {
            let m = Self.measured(.noaaAPT, sampleRate: 96_000, snr: snr, seed: 7 + seed, offsetHz: 6000)
            let label = "APT at \(snr) dB, seed \(seed)"
            #expect(m.family != .am && m.family != .carrier && m.family != .fsk, "\(label): \(m.family) \(m.notes)")
            if m.family == .fm {
                #expect(m.subcarriersHz.contains { abs($0 - 2400) <= 24 }, "\(label): \(m.subcarriersHz)")
            }
        }
    }

    /// Analog signals never take a digital family.
    @Test(arguments: [20.0, 10.0])
    func analogStaysAnalog(snr: Double) {
        let cases: [(SynthSpec, SignalFamily)] = [
            (.nfmVoice(deviationHz: 2500), .fm), (.nfmVoice(deviationHz: 5000), .fm), (.usbVoice, .usb),
            (.amVoice, .am), (.amBroadcast, .am), (.cw(wpm: 20), .ook), (.carrier, .carrier),
            (.fm(.tone(1000), deviationHz: 500), .fm), (.fm(.tone(400), deviationHz: 3000), .fm),
        ]
        for (index, (spec, family)) in cases.enumerated() {
            let m = Self.measured(spec, snr: snr, seed: UInt64(20 + index), fftSize: spec == .carrier ? 16_384 : 4096)
            #expect(m.family == family || m.family == .unknown, "\(spec) at \(snr) dB: \(m.family) \(m.notes)")
            #expect(![.fsk, .mfsk, .psk, .ofdm].contains(m.family), "\(spec) at \(snr) dB: \(m.family)")
        }
    }
}
