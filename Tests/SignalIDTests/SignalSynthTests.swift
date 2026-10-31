import Accelerate
import DSPCore
import Foundation
import Testing
@testable import SignalID

// Self-tests of the test-signal generator, so later tasks can trust it. Every check here uses an
// independent measurement (spectra, envelopes, a discriminator), never the generator's internals.

/// A low-cost plan for an independent SNR estimate: 6 × the occupied bandwidth, bins of at most 1/16 of it,
/// 256 frames.
private func analysisPlan(_ spec: SynthSpec) -> (rate: Double, size: Int, seconds: Double) {
    let b = spec.occupiedBandwidthHz
    let rate = 6 * b
    var size = 64
    while rate / Double(size) > b / 16 { size *= 2 }
    return (rate, size, 256 * Double(size) / rate)
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

    @Test func snrMatchesTheRequestForEveryMode() {
        // Independent estimate: noise density from the bins beyond ±1.5 B, the signal as everything above it,
        // over the noise in B (the occupied bandwidth).
        for (index, entry) in SynthSpec.catalogue.enumerated() {
            let plan = analysisPlan(entry.spec)
            let b = entry.spec.occupiedBandwidthHz
            for snr in [10.0, 3.0] {
                let iq = SignalSynth.make(entry.spec, sampleRate: plan.rate, seconds: plan.seconds, snrDb: snr,
                                          seed: UInt64(300 + index))
                let p = linear(PowerSpectrum.average(iq, size: plan.size, maxFrames: 4096))
                let binHz = plan.rate / Double(plan.size)
                let far = p.indices.filter { abs(Double($0 - plan.size / 2) * binHz) > 1.5 * b }
                let density = far.map { p[$0] }.reduce(0, +) / Double(far.count)
                let signal = p.reduce(0, +) - density * Double(p.count)
                let estimate = 10 * log10(signal / (density * b / binHz))
                #expect(abs(estimate - snr) <= 1, "\(entry.name) \(entry.spec) at \(snr) dB: estimated \(estimate) dB")
            }
        }
    }

    @Test func occupiedBandwidthIsTheRenderedWidth() {
        // The declared width is the rendered one by construction; an independent render (another seed, rate
        // and resolution, this file's own fixed-point search) agrees within 6%.
        for (index, entry) in SynthSpec.catalogue.enumerated() {
            let declared = entry.spec.occupiedBandwidthHz
            #expect(declared == SignalSynth.occupiedBandwidthHz(for: entry.spec))
            guard entry.spec != .carrier else { continue }
            // 10 × the width, 2048 bins (the cache uses 8 ×, 1024), over 2 s or 128 frames.
            let rate = 10 * declared, size = 2048
            let binHz = rate / Double(size)
            let seconds = min(max(128 * Double(size) / rate, 2), 1_000_000 / rate)
            let iq = SignalSynth.make(entry.spec, sampleRate: rate, seconds: seconds, snrDb: .infinity,
                                      seed: UInt64(900 + index))
            let p = linear(PowerSpectrum.average(iq, size: size, maxFrames: 4096))
            let total = p.reduce(0, +)
            var width = declared
            for _ in 0..<40 {
                // Edges where the density, averaged over ±1% of the width, falls to 1/100 of the mean
                // density over the width.
                let reach = max(1, Int((0.01 * width / binHz).rounded()))
                let threshold = total * binHz / (100 * width)
                let above = p.indices.filter { k in
                    let window = p[max(0, k - reach)...min(size - 1, k + reach)]
                    return window.reduce(0, +) / Double(window.count) >= threshold
                }
                let next = Double(above.last! - above.first! + 1) * binHz
                if abs(next - width) < binHz / 2 { width = next; break }
                width = next
            }
            #expect(abs(width / declared - 1) <= 0.06,
                    "\(entry.name) \(entry.spec): rendered \(width) Hz, declared \(declared)")
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
            let fs = max(2 * entry.spec.minimumSampleRate, 8000)
            let iq = SignalSynth.make(entry.spec, sampleRate: fs, seconds: 0.5, snrDb: 10, offsetHz: 0.05 * fs,
                                      seed: UInt64(index))
            #expect(iq.count == 2 * Int((0.5 * fs).rounded()))
            let finite = iq.allSatisfy { $0.isFinite }
            #expect(finite, "\(entry.name)")
        }
    }
}
