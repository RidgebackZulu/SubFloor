import Accelerate
import DSPCore
import Foundation
import Testing
@testable import SignalID

/// Task 3's families through `SignalMeasurer.measure`, each synthesised at 20 and 10 dB and found the way the
/// app finds it: the extent from `Extent.find` on an averaged spectrum is the seed. Seeds 1–50 only
/// (thresholds were tuned on seeds ≥ 1000).
@Suite struct AnalogFamilyTests {
    /// Synthesises `spec` at `offsetHz`, seeds the measurement with its extent and measures it.
    static func measured(_ spec: SynthSpec, sampleRate fs: Double = 48_000, snr: Double, seed: UInt64,
                         offsetHz: Double = 3000, seconds: Double = 3, fftSize: Int = 4096) -> SignalMeasurement {
        let iq = SignalSynth.make(spec, sampleRate: fs, seconds: seconds, snrDb: snr, offsetHz: offsetHz, seed: seed)
        let binHz = fs / Double(fftSize)
        let db = PowerSpectrum.average(iq, size: fftSize)
        let near = fftSize / 2 + Int((offsetHz / binHz).rounded())
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

    @Test(arguments: [20.0, 10.0])
    func noiseIsNoise(snr: Double) {
        for seed in UInt64(1)...3 {
            let iq = SignalSynth.make(.noise, sampleRate: 48_000, seconds: 3, snrDb: snr, seed: seed)
            let m = SignalMeasurer.measure(iq, sampleRate: 48_000, offsetHz: 3000, bandwidthHz: 2700, seconds: 3)
            #expect(m.family == .noise, "seed \(seed): \(m.family)")
            #expect(m.envelope == .none)
        }
    }

    @Test(arguments: [20.0, 10.0])
    func carrier(snr: Double) {
        for seed in UInt64(1)...3 {
            let m = Self.measured(.carrier, snr: snr, seed: seed, offsetHz: 1234.5, fftSize: 16_384)
            #expect(m.family == .carrier, "seed \(seed): \(m.family) \(m.notes)")
            #expect(m.envelope == .steady)
            #expect(abs(m.offsetHz - 1234.5) <= 1, "seed \(seed): \(m.offsetHz)")
        }
    }

    @Test(arguments: [20.0, 10.0])
    func cwKeyingSpeed(snr: Double) {
        for (index, (wpm, seconds)) in [(10.0, 4.0), (20, 3), (35, 3)].enumerated() {
            for seed in UInt64(1)...2 {
                let m = Self.measured(.cw(wpm: wpm), snr: snr, seed: UInt64(10 * index) + seed, seconds: seconds,
                                      fftSize: 16_384)
                #expect(m.family == .ook, "\(wpm) WPM seed \(seed): \(m.family) \(m.notes)")
                #expect(m.envelope == .keyed)
                #expect(Self.within(m.cwWPM, wpm, 0.10), "\(wpm) WPM seed \(seed): measured \(m.cwWPM ?? -1)")
            }
        }
    }

    @Test(arguments: [20.0, 10.0])
    func amCarrierWithSymmetricSidebands(snr: Double) {
        for (spec, envelope) in [(SynthSpec.amVoice, EnvelopeKind.voice), (.amBroadcast, .steady)] {
            for seed in UInt64(1)...3 {
                let m = Self.measured(spec, snr: snr, seed: seed)
                #expect(m.family == .am, "\(spec) seed \(seed): \(m.family)")
                #expect(m.envelope == envelope, "\(spec) seed \(seed): \(m.envelope)")
                #expect(Self.within(m.occupiedBandwidthHz, spec.occupiedBandwidthHz, 0.10),
                        "\(spec) seed \(seed): \(m.occupiedBandwidthHz) Hz of \(spec.occupiedBandwidthHz)")
                #expect(abs(m.offsetHz - 3000) <= 2, "the carrier is the centre: \(m.offsetHz)")
                #expect(abs(m.snrDb - snr) <= 1.5, "\(spec) seed \(seed): SNR \(m.snrDb)")
            }
        }
    }

    @Test(arguments: [20.0, 10.0])
    func ssbSideband(snr: Double) {
        for (spec, family) in [(SynthSpec.usbVoice, SignalFamily.usb), (.lsbVoice, .lsb)] {
            for seed in UInt64(1)...3 {
                let m = Self.measured(spec, snr: snr, seed: seed)
                #expect(m.family == family, "\(family) seed \(seed): \(m.family)")
                #expect(m.envelope == .voice)
                #expect(Self.within(m.occupiedBandwidthHz, spec.occupiedBandwidthHz, 0.10),
                        "\(family) seed \(seed): \(m.occupiedBandwidthHz) Hz of \(spec.occupiedBandwidthHz)")
                #expect(abs(m.snrDb - snr) <= 1.5, "\(family) seed \(seed): SNR \(m.snrDb)")
            }
        }
    }

    /// Within 15%: the synthesiser's NFM voice itself reaches 0.97–1.12 × its nominal deviation at the 99.9th
    /// percentile (its clipped audio, interpolated, overshoots the clip level), so 10% of nominal isn't a fair
    /// bound on every seed (tuning seeds: 0.955–1.148 at 20 and 10 dB). WFM's programme stays under its
    /// nominal peak and is held to 10% (`wfmPilot`).
    @Test(arguments: [20.0, 10.0])
    func fmDeviation(snr: Double) {
        for deviation in [2500.0, 5000] {
            for seed in UInt64(1)...3 {
                let m = Self.measured(.nfmVoice(deviationHz: deviation), snr: snr, seed: seed)
                #expect(m.family == .fm, "\(deviation) Hz seed \(seed): \(m.family) \(m.notes)")
                #expect(m.envelope == .steady)
                #expect(Self.within(m.fmDeviationHz, deviation, 0.15),
                        "\(deviation) Hz seed \(seed): measured \(m.fmDeviationHz ?? -1)")
            }
        }
    }

    @Test(arguments: [20.0, 10.0])
    func wfmPilot(snr: Double) {
        for seed in UInt64(1)...2 {
            let m = Self.measured(.wfmBroadcast, sampleRate: 1_000_000, snr: snr, seed: seed, offsetHz: 100_000,
                                  seconds: 1)
            #expect(m.family == .wfm, "seed \(seed): \(m.family)")
            #expect(m.subcarriersHz.contains { abs($0 - 19_000) <= 100 }, "seed \(seed): \(m.subcarriersHz)")
            #expect(Self.within(m.fmDeviationHz, 75_000, 0.10), "seed \(seed): measured \(m.fmDeviationHz ?? -1)")
        }
    }

    /// MW broadcast in a crowded band: equal-strength stations 9 or 10 kHz either side (noise-free, so the
    /// SNR is the middle one's). The middle one is still AM, its width its own.
    @Test(arguments: [20.0, 10.0])
    func crowdedMediumWaveIsStillAM(snr: Double) {
        let fs = 48_000.0
        for (index, spacing) in [9000.0, 10_000].enumerated() {
            for seed in UInt64(1)...2 {
                let base = UInt64(40 + 10 * index) + 3 * seed
                var iq = SignalSynth.make(.amBroadcast, sampleRate: fs, seconds: 3, snrDb: snr, seed: base)
                for (k, offset) in [-spacing, spacing].enumerated() {
                    let neighbour = SignalSynth.make(.amBroadcast, sampleRate: fs, seconds: 3, snrDb: .infinity,
                                                     offsetHz: offset, seed: base + UInt64(k + 1))
                    vDSP_vadd(iq, 1, neighbour, 1, &iq, 1, vDSP_Length(iq.count))
                }
                let size = 4096
                let binHz = fs / Double(size)
                guard let extent = Extent.find(spectrumDb: PowerSpectrum.average(iq, size: size), binHz: binHz,
                                               nearBin: size / 2, searchBins: 4) else {
                    Issue.record("\(spacing) Hz, seed \(seed): no extent")
                    continue
                }
                let width = Double(extent.upperBin - extent.lowerBin + 1) * binHz
                let centre = (Double(extent.lowerBin + extent.upperBin) / 2 - Double(size / 2)) * binHz
                let m = SignalMeasurer.measure(iq, sampleRate: fs, offsetHz: centre, bandwidthHz: width, seconds: 3)
                #expect(m.family == .am, "\(spacing) Hz spacing, seed \(seed): \(m.family) \(m.notes)")
                #expect(Self.within(m.occupiedBandwidthHz, SynthSpec.amBroadcast.occupiedBandwidthHz, 0.15),
                        "\(spacing) Hz spacing, seed \(seed): \(m.occupiedBandwidthHz) Hz")
            }
        }
    }

    /// NOAA APT pointed at its centre: the extent takes one line of a comb of Bessel lines 2.4 kHz apart, whose
    /// amplitude moves with the image. Neither AM nor a carrier.
    @Test(arguments: [20.0, 10.0])
    func aptCentreLineIsNotAM(snr: Double) {
        for seed in UInt64(1)...6 {
            let m = Self.measured(.noaaAPT, sampleRate: 96_000, snr: snr, seed: seed)
            #expect(m.family != .am && m.family != .carrier, "seed \(seed): \(m.family) \(m.notes)")
        }
    }

    /// Task 4's families must not be taken for these: `unknown`, or at worst a weak `fm` for a constant
    /// envelope FSK.
    @Test(arguments: [20.0, 10.0])
    func digitalFamiliesAreLeftAlone(snr: Double) {
        // (spec, sample rate, where the pointer rests relative to the centre: RTTY 850's centre is empty).
        let cases: [(SynthSpec, Double, Double)] = [
            (.rtty(baud: 45.45, shiftHz: 170), 48_000, 0), (.rtty(baud: 50, shiftHz: 850), 48_000, 425),
            (.navtex, 48_000, 0), (.psk31, 48_000, 0), (.qpsk31, 48_000, 0), (.hfdl, 48_000, 0),
            (.stanag4285, 48_000, 0), (.drm, 48_000, 0), (.p25, 48_000, 0), (.ysf, 48_000, 0), (.dstar, 48_000, 0),
            (.ale, 48_000, 0), (.olivia(), 48_000, 0), (.mfsk16, 48_000, 0), (.ft8(), 48_000, 0), (.dmr, 48_000, 0),
            (.ais, 96_000, 0),
            // NOAA APT pointed at its centre: the extent takes one Bessel line of a ±17 kHz FM.
            (.noaaAPT, 96_000, 0),
        ]
        for (index, (spec, fs, point)) in cases.enumerated() {
            let seed = UInt64(20 + index)
            let iq = SignalSynth.make(spec, sampleRate: fs, seconds: 3, snrDb: snr, offsetHz: 3000, seed: seed)
            let size = 4096
            let binHz = fs / Double(size)
            let db = PowerSpectrum.average(iq, size: size)
            let near = size / 2 + Int(((3000 + point) / binHz).rounded())
            guard let extent = Extent.find(spectrumDb: db, binHz: binHz, nearBin: near, searchBins: 4) else {
                Issue.record("\(spec) at \(snr) dB, seed \(seed): no extent")
                continue
            }
            let width = Double(extent.upperBin - extent.lowerBin + 1) * binHz
            let centre = (Double(extent.lowerBin + extent.upperBin) / 2 - Double(size / 2)) * binHz
            let m = SignalMeasurer.measure(iq, sampleRate: fs, offsetHz: centre, bandwidthHz: width, seconds: 3)
            let leftAlone = m.family == .unknown || (m.family == .fm && m.familyConfidence <= 0.5)
            #expect(leftAlone, "\(spec) at \(snr) dB: \(m.family) \(m.familyConfidence) \(m.notes)")
        }
    }

    /// 3 s at 2 MS/s with a 12.5 kHz signal: ≤ 150 ms in a release build (`swift test -c release`). Debug
    /// builds (-Onone) only check the answer.
    @Test func firstPassBudget() {
        let fs = 2_000_000.0
        let iq = SignalSynth.make(.nfmVoice(deviationHz: 5000), sampleRate: fs, seconds: 3, snrDb: 20,
                                  offsetHz: 250_000, seed: 7)
        _ = SignalMeasurer.measure(iq, sampleRate: fs, offsetHz: 250_000, bandwidthHz: 12_500, seconds: 3)
        let clock = ContinuousClock()
        var m = SignalMeasurement()
        let elapsed = clock.measure {
            m = SignalMeasurer.measure(iq, sampleRate: fs, offsetHz: 250_000, bandwidthHz: 12_500, seconds: 3)
        }
        #expect(m.family == .fm)
        print("firstPassBudget: \(elapsed)")
        if Self.optimised() {
            #expect(elapsed <= .milliseconds(150), "measure took \(elapsed)")
        }
    }

    /// True in an optimised build. Not inlined, so a debug build doesn't see the branch as dead code.
    @inline(never) static func optimised() -> Bool { !_isDebugAssertConfiguration() }
}
