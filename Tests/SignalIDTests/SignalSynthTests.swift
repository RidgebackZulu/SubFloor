import Accelerate
import DSPCore
import Foundation
import Testing
@testable import SignalID

// Self-tests of the test-signal generator, so later tasks can trust it. Every check here uses an
// independent measurement (spectra, envelopes, a discriminator), never the generator's internals.

/// A sample rate and FFT size that resolve `spec`: 16 × its bandwidth, bins of at most 1/50 of it, and
/// enough seconds for 8 frames.
private func analysisPlan(_ spec: SynthSpec) -> (rate: Double, size: Int, seconds: Double) {
    let b = spec.occupiedBandwidthHz
    let rate: Double = b > 1_000_000 ? 2_048_000 : max(16 * b, 800)
    var size = 256
    while rate / Double(size) > b / 50 && size < 65_536 { size *= 2 }
    let seconds: Double = max(3, 8 * Double(size) / rate)
    return (rate, size, seconds)
}

/// Power in each bin (linear), from dB.
private func linear(_ db: [Float]) -> [Double] { db.map { (x: Float) -> Double in pow(10.0, Double(x) / 10) } }

/// |x|² per complex sample of interleaved IQ.
private func power(_ iq: [Float]) -> [Float] {
    (0..<(iq.count / 2)).map { (i: Int) -> Float in
        let re = iq[2 * i], im = iq[2 * i + 1]
        return re * re + im * im
    }
}

/// Moving average over `width` samples (centred).
private func smooth(_ x: [Float], width: Int) -> [Float] {
    var prefix = [Double](repeating: 0, count: x.count + 1)
    for i in x.indices { prefix[i + 1] = prefix[i] + Double(x[i]) }
    return x.indices.map { i in
        let lo = max(0, i - width / 2), hi = min(x.count, i + width / 2 + 1)
        return Float((prefix[hi] - prefix[lo]) / Double(hi - lo))
    }
}

/// Lengths (in samples) of the runs where `x` is at or above `threshold`, and where each starts.
private func runs(_ x: [Float], above threshold: Float) -> [(start: Int, length: Int)] {
    var out: [(Int, Int)] = []
    var start: Int?
    for i in x.indices {
        if x[i] >= threshold { if start == nil { start = i } } else if let s = start {
            out.append((s, i - s))
            start = nil
        }
    }
    return out
}

@Suite struct SignalSynthTests {
    @Test func deterministicFromSeedWithTheNoiseOnTop() {
        let fs = 48_000.0
        let a = SignalSynth.make(.rtty(), sampleRate: fs, seconds: 0.5, snrDb: 10, offsetHz: 900, seed: 1)
        let b = SignalSynth.make(.rtty(), sampleRate: fs, seconds: 0.5, snrDb: 10, offsetHz: 900, seed: 1)
        let c = SignalSynth.make(.rtty(), sampleRate: fs, seconds: 0.5, snrDb: 10, offsetHz: 900, seed: 2)
        #expect(a.count == 2 * 24_000)
        #expect(a == b)
        #expect(a != c)
        // The same seed without noise is the same signal: the difference is the noise, at the power the
        // SNR asks for (unit signal power, so noise = fs / B × 10^(−SNR/10)).
        let clean = SignalSynth.make(.rtty(), sampleRate: fs, seconds: 0.5, snrDb: .infinity, offsetHz: 900, seed: 1)
        let signal = power(clean).reduce(0, +) / Float(clean.count / 2)
        #expect(abs(signal - 1) < 0.01)
        var residual = a
        vDSP_vsub(clean, 1, a, 1, &residual, 1, vDSP_Length(a.count))
        let noise = Double(power(residual).reduce(0, +)) / Double(a.count / 2)
        let expected = fs / SynthSpec.rtty().occupiedBandwidthHz / 10
        #expect(abs(noise / expected - 1) < 0.03)
    }

    @Test func fskTonesSitWhereTheyShould() {
        // 2-FSK: tones at ±shift/2 of the offset.
        let fs = 8000.0
        let size = 8192
        let binHz = fs / Double(size)
        let rtty = PowerSpectrum.average(SignalSynth.make(.rtty(baud: 50, shiftHz: 850), sampleRate: fs, seconds: 4,
                                                          snrDb: 20, offsetHz: 1000, seed: 3), size: size)
        #expect(abs(peakHz(rtty, binHz: binHz, in: 0...1000) - 575) <= binHz)
        #expect(abs(peakHz(rtty, binHz: binHz, in: 1000...2000) - 1425) <= binHz)

        // 8-FSK (ALE: 250 Hz spacing, an integer index so each tone is a line): the eight strongest peaks
        // are the eight tones.
        let ale = PowerSpectrum.average(SignalSynth.make(.ale, sampleRate: fs, seconds: 4, snrDb: 20,
                                                         offsetHz: -500, seed: 4), size: size)
        var peaks: [Int] = []
        for k in 2..<(size - 2) where ale[k] > ale[k - 1] && ale[k] >= ale[k + 1] && ale[k] > ale[k - 2]
            && ale[k] >= ale[k + 2] { peaks.append(k) }
        let tones = peaks.sorted { ale[$0] > ale[$1] }.prefix(8).map { Double($0 - size / 2) * binHz }.sorted()
        let expected = (0..<8).map { -500 + (Double($0) - 3.5) * 250 }
        #expect(tones.count == 8)
        for (found, want) in zip(tones, expected) { #expect(abs(found - want) <= binHz, "tone \(want): \(found)") }
    }

    @Test func snrMatchesTheRequest() {
        // Independent estimate: noise density from the bins beyond ±B, the signal as everything above it.
        let specs: [SynthSpec] = [.rtty(), .navtex, .psk31, .usbVoice, .amVoice, .nfmVoice(), .stanag4285, .drm,
                                  .p25, .dmr, .ft8(captureStartInSlot: 0), .olivia(), .hfFax(), .aprs]
        for (index, spec) in specs.enumerated() {
            let plan = analysisPlan(spec)
            let b = spec.occupiedBandwidthHz
            for snr in [10.0, 3.0] {
                let iq = SignalSynth.make(spec, sampleRate: plan.rate, seconds: plan.seconds, snrDb: snr,
                                          offsetHz: 0, seed: UInt64(300 + index))
                let p = linear(PowerSpectrum.average(iq, size: plan.size, maxFrames: 4096))
                let binHz = plan.rate / Double(plan.size)
                let far = p.indices.filter { abs(Double($0 - plan.size / 2) * binHz) > b }
                let density = far.map { p[$0] }.reduce(0, +) / Double(far.count)
                let signal = p.reduce(0, +) - density * Double(p.count)
                let estimate = 10 * log10(signal / (density * b / binHz))
                #expect(abs(estimate - snr) <= 1, "\(spec) at \(snr) dB: estimated \(estimate) dB")
            }
        }
    }

    @Test func occupiedBandwidthMatchesTheSpectrum() {
        // The declared −20 dB width against the clean spectrum's (levels smoothed over 3 bins). Modes whose
        // spectrum is a carrier line with weak sidebands (AM, NFM voice, CW) are left out: there the −20 dB
        // width depends on the resolution, and the declared width is the conventional one.
        let specs: [SynthSpec] = [.usbVoice, .rtty(baud: 45.45, shiftHz: 170), .rtty(baud: 50, shiftHz: 850),
                                  .rtty(baud: 75, shiftHz: 425), .navtex, .psk31, .psk63, .ft8(), .ft4(), .wspr(),
                                  .olivia(), .olivia(tones: 8, bandwidthHz: 250), .mfsk16, .ale, .stanag4285,
                                  .hfFax(), .drm, .hfdl, .pocsag(baud: 512), .pocsag(baud: 2400), .dmr, .p25,
                                  .nxdn(baud: 2400), .nxdn(baud: 4800), .dstar, .ysf, .ais, .msk(rate: 2400),
                                  .noaaAPT]
        for (index, spec) in specs.enumerated() {
            let plan = analysisPlan(spec)
            let iq = SignalSynth.make(spec, sampleRate: plan.rate, seconds: plan.seconds, snrDb: .infinity,
                                      seed: UInt64(400 + index))
            let p = linear(PowerSpectrum.average(iq, size: plan.size, maxFrames: 4096))
            let level = p.indices.map { k in p[max(0, k - 1)...min(p.count - 1, k + 1)].reduce(0, +) }
            let top = level.max()!
            let above = level.indices.filter { level[$0] >= top / 100 }
            let width = Double(above.last! - above.first! + 1) * plan.rate / Double(plan.size)
            let ratio = width / spec.occupiedBandwidthHz
            #expect(ratio > 0.85 && ratio < 1.15, "\(spec): −20 dB width \(width) Hz, declared \(spec.occupiedBandwidthHz)")
        }
    }

    @Test func burstsFollowTheirSchedule() {
        // DMR: 27.5 ms on in every 60 ms (its 1 ms ramps take about 1 ms off the length at half power).
        let fs = 48_000.0
        let dmr = smooth(power(SignalSynth.make(.dmr, sampleRate: fs, seconds: 1, snrDb: 40, seed: 5)), width: 24)
        let on = runs(dmr, above: 0.5 * dmr.max()!)
        let full = on.filter { $0.start > 0 && $0.start + $0.length < dmr.count }
        #expect(full.count >= 14)
        for r in full { #expect(abs(Double(r.length) / fs - 0.0265) < 0.001) }
        for (a, b) in zip(full, full.dropFirst()) { #expect(abs(Double(b.start - a.start) / fs - 0.06) < 0.0005) }

        // FT8 from the slot start: on at 0.5 s.
        let ft8 = smooth(power(SignalSynth.make(.ft8(captureStartInSlot: 0), sampleRate: 4000, seconds: 3,
                                                snrDb: 40, seed: 6)), width: 40)
        let start = ft8.firstIndex { $0 >= 0.5 * ft8.max()! }!
        #expect(abs(Double(start) / 4000 - 0.5) < 0.02)
    }

    @Test func cwKeysAtItsWPM() {
        let fs = 8000.0
        for wpm in [12.0, 25.0] {
            let key = smooth(power(SignalSynth.make(.cw(wpm: wpm), sampleRate: fs, seconds: 8, snrDb: 40, seed: 7)),
                             width: 16)
            let lengths = runs(key, above: 0.5 * key.max()!).map { Double($0.length) / fs }.sorted()
            let dot = 1.2 / wpm
            #expect(lengths.count >= 8)
            // The shortest key-downs are dots; the longest dashes (3 dots).
            #expect(abs(lengths[lengths.count / 10] / dot - 1) < 0.1, "\(wpm) WPM: \(lengths.prefix(5))")
            #expect(abs(lengths[lengths.count - 2] / (3 * dot) - 1) < 0.1)
        }
    }

    @Test func fmCarriesItsSubcarriers() {
        // A discriminator on WFM shows the 19 kHz pilot; on APT, the 2400 Hz subcarrier.
        for (spec, fs, tone) in [(SynthSpec.wfmBroadcast, 480_000.0, 19_000.0), (.noaaAPT, 96_000.0, 2400.0)] {
            let iq = SignalSynth.make(spec, sampleRate: fs, seconds: 1, snrDb: 30, seed: 8)
            var audio = [DSPComplex]()
            for i in 1..<(iq.count / 2) {
                let (a, b) = (iq[2 * i], iq[2 * i + 1])
                let (c, d) = (iq[2 * i - 2], -iq[2 * i - 1])
                audio.append(DSPComplex(real: atan2(a * d + b * c, a * c - b * d), imag: 0))
            }
            let size = 16_384
            let binHz = fs / Double(size)
            let db = PowerSpectrum.average(audio, size: size)
            let line = db[bin(tone, binHz: binHz, size: size)]
            let around = (bin(tone - 3000, binHz: binHz, size: size)...bin(tone + 3000, binHz: binHz, size: size))
                .map { db[$0] }.sorted()
            #expect(line > around[around.count / 2] + 15, "\(tone) Hz line in \(spec)")
        }
    }

    @Test func driftAndFadeAreApplied() {
        let fs = 1000.0
        let size = 1024
        let binHz = fs / Double(size)
        let iq = SignalSynth.make(.carrier, sampleRate: fs, seconds: 10, snrDb: 40, offsetHz: 100, seed: 9,
                                  impairments: SynthImpairments(driftHzPerSecond: 2))
        let first = PowerSpectrum.average(Array(iq[0..<(2 * size)]), size: size)
        let last = PowerSpectrum.average(Array(iq[(iq.count - 2 * size)...]), size: size)
        // Centred drift: about −9 Hz in the first second, +9 Hz in the last.
        #expect(abs(peakHz(first, binHz: binHz, in: 50...150) - 91) < 1.5)
        #expect(abs(peakHz(last, binHz: binHz, in: 50...150) - 109) < 1.5)

        let faded = smooth(power(SignalSynth.make(.carrier, sampleRate: fs, seconds: 20, snrDb: 40, seed: 10,
                                                  impairments: SynthImpairments(fadeDepthDb: 20, fadeRateHz: 0.5))),
                           width: 50)
        let swing = 10 * log10(Double(faded.max()!) / Double(faded.min()!))
        #expect(swing > 10 && swing < 21)
    }

    @Test func everyCatalogueEntrySynthesises() {
        #expect(Set(SynthSpec.catalogue.map(\.name)).count == 30)
        for (index, entry) in SynthSpec.catalogue.enumerated() {
            let fs = entry.spec.occupiedBandwidthHz > 1_000_000 ? 2_048_000 : max(2 * entry.spec.minimumSampleRate, 8000)
            let iq = SignalSynth.make(entry.spec, sampleRate: fs, seconds: 0.5, snrDb: 10, offsetHz: 0.05 * fs,
                                      seed: UInt64(index))
            #expect(iq.count == 2 * Int((0.5 * fs).rounded()))
            let finite = iq.allSatisfy { $0.isFinite }
            #expect(finite, "\(entry.name)")
        }
    }
}
