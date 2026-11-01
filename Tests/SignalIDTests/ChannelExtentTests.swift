import Accelerate
import DSPCore
import Testing
@testable import SignalID

/// Frequency of the strongest bin of an FFT-shifted spectrum within `range` (Hz from its centre).
func peakHz(_ db: [Float], binHz: Double, in range: ClosedRange<Double>) -> Double {
    let centre = db.count / 2
    let lo = max(0, centre + Int((range.lowerBound / binHz).rounded(.up)))
    let hi = min(db.count - 1, centre + Int((range.upperBound / binHz).rounded(.down)))
    var best = lo
    for k in lo...hi where db[k] > db[best] { best = k }
    return Double(best - centre) * binHz
}

/// FFT-shifted bin of `hz` in a spectrum of `size` bins.
func bin(_ hz: Double, binHz: Double, size: Int) -> Int { size / 2 + Int((hz / binHz).rounded()) }

/// Task 2's channel and extent. `snrIsMeasuredInTheSignalsBandwidth` runs its first seed by default, both with
/// `SUBFLOOR_SIGNALID_MATRIX=1` (`Sweep`, ruling R32).
@Suite(.serialized) struct ChannelExtentTests {
    /// The streaming extractor (Signal ID's longer read, fed off the ring a piece at a time) gives `extract`'s
    /// output, whatever the pieces: odd sizes, ones under a mixer block, ones across several.
    @Test func extractorMatchesExtractPieceByPiece() {
        let fs = 2_000_000.0
        let iq = SignalSynth.make(.rtty(baud: 50, shiftHz: 850), sampleRate: fs, seconds: 0.4, snrDb: 20,
                                  offsetHz: 37_000, seed: 13)
        for sharp in [true, false] {
            let whole = Channel.extract(iq, sampleRate: fs, offsetHz: 37_000, bandwidthHz: 48_000, sharp: sharp)
            for pieceFrames in [1_000, 4_096, 9_999, 300_000] {
                let extractor = ChannelExtractor(sampleRate: fs, offsetHz: 37_000, bandwidthHz: 48_000, sharp: sharp)
                iq.withUnsafeBufferPointer { p in
                    var start = 0
                    while start < p.count {
                        let end = min(start + 2 * pieceFrames, p.count)
                        extractor.feed(UnsafeBufferPointer(rebasing: p[start..<end]))
                        start = end
                    }
                }
                let out = extractor.finish()
                #expect(out.rate == whole.rate)
                #expect(out.samples.count == 2 * whole.samples.count, "\(pieceFrames)-frame pieces")
                var worst: Float = 0
                for (k, z) in whole.samples.enumerated() where 2 * k + 1 < out.samples.count {
                    worst = max(worst, abs(out.samples[2 * k] - z.real), abs(out.samples[2 * k + 1] - z.imag))
                }
                #expect(worst < 1e-5, "\(pieceFrames)-frame pieces, sharp \(sharp): off by \(worst)")
            }
        }
    }

    @Test func channelCentresAndDecimates() {
        let fs = 2_000_000.0
        let fsk = SignalSynth.make(.rtty(baud: 50, shiftHz: 850), sampleRate: fs, seconds: 2, snrDb: 20,
                                   offsetHz: 37_000, seed: 11)
        // A strong carrier 15 kHz above, outside the 10 kHz channel, must not come through.
        let neighbour = SignalSynth.make(.carrier, sampleRate: fs, seconds: 2, snrDb: 60, offsetHz: 52_000, seed: 12)
        var iq = fsk
        vDSP_vadd(fsk, 1, neighbour, 1, &iq, 1, vDSP_Length(iq.count))

        let channel = Channel.extract(iq, sampleRate: fs, offsetHz: 37_000, bandwidthHz: 10_000)
        #expect(channel.rate >= 40_000 && channel.rate < 80_000)
        #expect(abs(Double(channel.samples.count) - 2 * channel.rate) <= 2)

        let size = 8192
        let db = PowerSpectrum.average(channel.samples, size: size)
        let binHz = channel.rate / Double(size)
        #expect(abs(peakHz(db, binHz: binHz, in: -2000 ... -1) + 425) <= binHz)
        #expect(abs(peakHz(db, binHz: binHz, in: 1 ... 2000) - 425) <= binHz)
        // In-channel noise, between the tones' skirts and the band edge.
        let inBand = db[bin(1000, binHz: binHz, size: size)...bin(4000, binHz: binHz, size: size)].sorted()
        let floor = inBand[inBand.count / 2]
        let tone = db[bin(15_000, binHz: binHz, size: size)]
        #expect(tone < floor, "neighbour carrier leaked into the channel: \(tone - floor) dB over the noise")
    }

    @Test func extentFindsTheSignalWidth() {
        let fs = 192_000.0
        let size = 16_384
        let binHz = fs / Double(size)
        let cases: [(SynthSpec, Double)] = [
            (.psk(.init(order: 2, rate: 400, shape: .rootRaisedCosine(rolloff: 0.25))), 500),
            (.usbVoice, 2700),
            (.ofdm(.init(carriers: 299, spacingHz: 12_500 / 299.0)), 12_500),
        ]
        for (index, (spec, width)) in cases.enumerated() {
            #expect(abs(spec.nominalBandwidthHz - width) < 1)
            let offset = 6000.0
            let iq = SignalSynth.make(spec, sampleRate: fs, seconds: 3, snrDb: 20, offsetHz: offset,
                                      seed: UInt64(100 + index))
            let db = PowerSpectrum.average(iq, size: size)
            let found = Extent.find(spectrumDb: db, binHz: binHz, nearBin: bin(offset, binHz: binHz, size: size),
                                    searchBins: 4)
            #expect(found != nil, "no extent for \(width) Hz")
            guard let found else { continue }
            let measured = Double(found.upperBin - found.lowerBin + 1) * binHz
            let truth = spec.occupiedBandwidthHz
            #expect(abs(measured / truth - 1) <= 0.10,
                    "\(width) Hz signal (\(truth) Hz occupied) measured as \(measured) Hz")
            let centre = Double(found.lowerBin + found.upperBin) / 2
            #expect(abs((centre - Double(size / 2)) * binHz - offset) <= 0.05 * width)
        }
    }

    @Test func snrIsMeasuredInTheSignalsBandwidth() {
        let fs = 96_000.0
        let size = 8192
        let binHz = fs / Double(size)
        let specs: [SynthSpec] = [
            .psk(.init(order: 4, rate: 2400, shape: .rootRaisedCosine(rolloff: 0.35))),
            .usbVoice,
            .drm,
        ]
        for (index, spec) in specs.enumerated() {
            for seed in Sweep.seeds(1...2) {
                let offset = -8000.0
                let iq = SignalSynth.make(spec, sampleRate: fs, seconds: 3, snrDb: 10, offsetHz: offset,
                                          seed: UInt64(200 + 10 * index) + seed)
                let db = PowerSpectrum.average(iq, size: size)
                let found = Extent.find(spectrumDb: db, binHz: binHz,
                                        nearBin: bin(offset, binHz: binHz, size: size), searchBins: 4)
                #expect(found != nil)
                guard let found else { continue }
                #expect(abs(found.snrDb - 10) <= 1.5, "\(spec) seed \(seed): SNR \(found.snrDb) dB")
            }
        }
    }

    @Test func amIsOneSignalAndFSKTonesAreTheirOwn() {
        // Pointing at an AM carrier takes in its symmetric sidebands, across the voice's low-cut gap too, at
        // 11.7 and 23.4 Hz bins.
        for (index, (spec, fs)) in [(SynthSpec.amBroadcast, 48_000.0), (.amVoice, 48_000), (.amBroadcast, 96_000),
                                    (.amVoice, 96_000)].enumerated() {
            let size = 4096
            let binHz = fs / Double(size)
            let iq = SignalSynth.make(spec, sampleRate: fs, seconds: 4, snrDb: 20, seed: UInt64(500 + index))
            let found = Extent.find(spectrumDb: PowerSpectrum.average(iq, size: size), binHz: binHz,
                                    nearBin: size / 2, searchBins: 4)
            #expect(found != nil, "\(spec)")
            guard let found else { continue }
            let width = Double(found.upperBin - found.lowerBin + 1) * binHz
            #expect(abs(width / spec.occupiedBandwidthHz - 1) <= 0.25,
                    "\(spec): \(width) Hz of \(spec.occupiedBandwidthHz)")
        }
        // The tones of a wide-shift FSK are two extents: spectrally they are two equal signals, and pairing
        // them is the FSK measurement's job.
        let fs = 8000.0, size = 4096
        let binHz = fs / Double(size)
        let iq = SignalSynth.make(.rtty(baud: 50, shiftHz: 850), sampleRate: fs, seconds: 4, snrDb: 20, seed: 510)
        let found = Extent.find(spectrumDb: PowerSpectrum.average(iq, size: size), binHz: binHz,
                                nearBin: bin(425, binHz: binHz, size: size), searchBins: 4)
        #expect(found != nil)
        if let found {
            #expect(found.lowerBin > bin(0, binHz: binHz, size: size), "the extent reached the other tone")
            #expect((found.lowerBin...found.upperBin).contains(bin(425, binHz: binHz, size: size)))
        }
    }

    @Test func neighboursAreNotMerged() {
        // Hand-built averaged spectra (noise −100 dB): each pointed-at signal comes back alone.
        func check(_ signals: [(centreHz: Double, widthHz: Double, levelDb: Double)], binHz: Double,
                   point: Int, expectHz: Double, _ label: String) {
            let db = handBuilt(bins: 4096, binHz: binHz, signals: signals)
            let pointBin = Int((signals[point].centreHz / binHz).rounded())
            let found = Extent.find(spectrumDb: db, binHz: binHz, nearBin: pointBin, searchBins: 4)
            #expect(found != nil, "\(label)")
            guard let found else { return }
            let width = Double(found.upperBin - found.lowerBin + 1) * binHz
            // The hand-built shoulders and the smoothing add up to 3 bins a side.
            #expect(abs(width - expectHz) <= 0.1 * expectHz + 6 * binHz, "\(label): \(width) Hz, expected \(expectHz)")
            #expect((found.lowerBin...found.upperBin).contains(pointBin), "\(label)")
            for (i, other) in signals.enumerated() where i != point {
                let otherBin = Int((other.centreHz / binHz).rounded())
                #expect(!(found.lowerBin...found.upperBin).contains(otherBin), "\(label): took in \(other.centreHz) Hz")
            }
        }
        // Three FT8-like 50 Hz signals at 1000, 1200 and 1500 Hz.
        let ft8 = [(1000.0, 50.0, -80.0), (1200, 50, -80), (1500, 50, -80)]
        for i in 0..<3 { check(ft8, binHz: 3.125, point: i, expectHz: 50, "FT8 \(i)") }
        // Two 80 Hz CW signals 800 Hz apart.
        let cw = [(1000.0, 80.0, -75.0), (1800, 80, -75)]
        for i in 0..<2 { check(cw, binHz: 5, point: i, expectHz: 80, "CW \(i)") }
        // Two 7.5 kHz NFM signals in adjacent 12.5 kHz channels.
        let nfm = [(25_000.0, 7500.0, -80.0), (37_500, 7500, -80)]
        for i in 0..<2 { check(nfm, binHz: 50, point: i, expectHz: 7500, "NFM \(i)") }
        // Near-symmetric FT8-like neighbours about the pointed-at one, at coarse resolutions where a 50 Hz
        // signal is only a few bins wide: 1000/1200/1400–1460 Hz and 900/1200/1500–1560 Hz, pointing at 1200.
        for binHz in [11.72, 23.4] {
            for third in stride(from: 1400.0, through: 1460, by: 20) {
                check([(1000, 50, -80), (1200, 50, -80), (third, 50, -80)], binHz: binHz, point: 1, expectHz: 50,
                      "FT8 1000/1200/\(third) at \(binHz) Hz bins")
            }
            for third in stride(from: 1500.0, through: 1560, by: 20) {
                check([(900, 50, -80), (1200, 50, -80), (third, 50, -80)], binHz: binHz, point: 1, expectHz: 50,
                      "FT8 900/1200/\(third) at \(binHz) Hz bins")
            }
        }
        // A weak carrier 400 Hz below an SSB signal (5650–8350 Hz), far from the array's edges, so the mirror
        // rule (not the edge) is what keeps them apart: pointing at either gives just that one.
        let ssb = [(7000.0, 2700.0, -80.0), (5250, 0, -76)]
        check(ssb, binHz: 5, point: 0, expectHz: 2700, "SSB beside a carrier")
        check(ssb, binHz: 5, point: 1, expectHz: 25, "carrier beside SSB")
        // The same carrier with symmetric neighbours as strong as itself (two more carriers 400 Hz either
        // side): still the carrier alone.
        let triple = [(5250.0, 0.0, -76.0), (4850, 0, -76), (5650, 0, -76)]
        check(triple, binHz: 5, point: 0, expectHz: 25, "carrier between equal carriers")
    }

    @Test func noiseAndSplatterAreNotNamed() {
        // Pure noise: nowhere is a signal.
        let fs = 48_000.0
        let size = 4096
        let noise = PowerSpectrum.average(SignalSynth.make(.noise, sampleRate: fs, seconds: 3, snrDb: 0, seed: 5),
                                          size: size)
        for near in stride(from: 40, to: size - 40, by: 97) {
            #expect(Extent.find(spectrumDb: noise, binHz: fs / Double(size), nearBin: near, searchBins: 6) == nil,
                    "noise named at bin \(near)")
        }

        // Three bandwidths beside a 40 dB carrier (house window): only its leakage is there.
        let iq = SignalSynth.make(.carrier, sampleRate: fs, seconds: 3, snrDb: 40, offsetHz: 1234.5, seed: 6)
        let db = PowerSpectrum.average(iq, size: size)
        let binHz = fs / Double(size)
        let carrierBin = bin(1234.5, binHz: binHz, size: size)
        let carrier = Extent.find(spectrumDb: db, binHz: binHz, nearBin: carrierBin, searchBins: 2)
        #expect(carrier != nil)
        if let carrier {
            let width = carrier.upperBin - carrier.lowerBin + 1
            for side in [-1, 1] {
                #expect(Extent.find(spectrumDb: db, binHz: binHz, nearBin: carrierBin + side * 3 * width,
                                    searchBins: width) == nil)
            }
        }

        // A strong carrier's skirt, falling as 1/f² (rectangular-window leakage), still well above the
        // noise where the pointer is: the skirt rises out of the search window, so it is not a signal there.
        let floorDb: Float = -100
        let peakBin = 1000
        var skirt = [Float](repeating: 0, count: 4096)
        var random = SystemNoise(seed: 9)
        for k in skirt.indices {
            let d = Double(abs(k - peakBin))
            let leak = d == 0 ? -40.0 : -40 - 20 * log10(Double.pi * d)
            let noise = pow(10, Double(floorDb) / 10) * (1 + 0.1 * random.next())
            skirt[k] = Float(10 * log10(pow(10, leak / 10) + noise))
        }
        let near = peakBin + 30
        let window = skirt[(near - 4)...(near + 4)].max()!
        #expect(window > floorDb + 6, "the test needs a skirt that stands above the noise")
        #expect(Extent.find(spectrumDb: skirt, binHz: 10, nearBin: near, searchBins: 4) == nil)
        #expect(Extent.find(spectrumDb: skirt, binHz: 10, nearBin: peakBin, searchBins: 4) != nil)
    }
}

/// An averaged spectrum built by hand: noise at −100 dB with ±0.3 dB of deterministic ripple, signals with
/// flat tops (`widthHz` wide at `levelDb`) and 2-bin raised-cosine shoulders, and lines (`widthHz` 0) with a
/// Blackman-Harris-like main lobe (0, −6, −30, −70 dB at 0, ±1, ±2, ±3 bins). Bin k is k × `binHz`.
func handBuilt(bins: Int, binHz: Double, signals: [(centreHz: Double, widthHz: Double, levelDb: Double)]) -> [Float] {
    var random = SystemNoise(seed: 77)
    var power = (0..<bins).map { _ in pow(10, (-100 + 0.3 * random.next()) / 10) }
    for s in signals {
        let centre = s.centreHz / binHz
        if s.widthHz == 0 {
            for (offset, db) in [(0, 0.0), (1, -6), (2, -30), (3, -70)] {
                let c = Int(centre.rounded())
                for k in Set([c - offset, c + offset]) where k >= 0 && k < bins {
                    power[k] += pow(10, (s.levelDb + db) / 10)
                }
            }
            continue
        }
        let half = s.widthHz / 2 / binHz
        for k in 0..<bins {
            let outside = abs(Double(k) - centre) - half
            let gain = outside <= 0 ? 1 : outside >= 2 ? 0 : 0.5 + 0.5 * cos(Double.pi * outside / 2)
            power[k] += gain * pow(10, s.levelDb / 10)
        }
    }
    return power.map { Float(10 * log10($0)) }
}

/// Uniform −1…1, deterministic (LCG): just enough roughness for a hand-built spectrum.
struct SystemNoise {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53) * 2 - 1
    }
}
