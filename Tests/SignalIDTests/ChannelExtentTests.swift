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

@Suite struct ChannelExtentTests {
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
            #expect(abs(spec.occupiedBandwidthHz - width) < 1)
            let offset = 6000.0
            let iq = SignalSynth.make(spec, sampleRate: fs, seconds: 3, snrDb: 20, offsetHz: offset,
                                      seed: UInt64(100 + index))
            let db = PowerSpectrum.average(iq, size: size)
            let found = Extent.find(spectrumDb: db, binHz: binHz, nearBin: bin(offset, binHz: binHz, size: size),
                                    searchBins: 4)
            #expect(found != nil, "no extent for \(width) Hz")
            guard let found else { continue }
            let measured = Double(found.upperBin - found.lowerBin + 1) * binHz
            #expect(abs(measured / width - 1) <= 0.10, "\(width) Hz measured as \(measured) Hz")
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
            for seed in UInt64(1)...2 {
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

    @Test func wideShiftFSKAndAMAreEachOneSignal() {
        // Pointing at one tone of a wide-shift FSK, or at an AM carrier, takes in the whole signal.
        let cases: [(SynthSpec, Double, Double)] = [   // spec, sample rate, where to point (Hz from centre)
            (.rtty(baud: 50, shiftHz: 850), 16_000, 425),
            (.rtty(baud: 45.45, shiftHz: 170), 8000, -85),
            (.pocsag(baud: 1200), 192_000, -4500),
            (.amBroadcast, 96_000, 0),
            (.amVoice, 96_000, 0),
        ]
        for (index, (spec, fs, point)) in cases.enumerated() {
            let size = 4096
            let binHz = fs / Double(size)
            let iq = SignalSynth.make(spec, sampleRate: fs, seconds: 4, snrDb: 20, seed: UInt64(500 + index))
            let db = PowerSpectrum.average(iq, size: size)
            let found = Extent.find(spectrumDb: db, binHz: binHz, nearBin: bin(point, binHz: binHz, size: size),
                                    searchBins: 4)
            #expect(found != nil, "\(spec)")
            guard let found else { continue }
            let width = Double(found.upperBin - found.lowerBin + 1) * binHz
            #expect(width >= 0.7 * spec.occupiedBandwidthHz && width <= 1.4 * spec.occupiedBandwidthHz,
                    "\(spec): \(width) Hz of \(spec.occupiedBandwidthHz)")
        }
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

/// Uniform −1…1, deterministic (LCG): just enough roughness for a hand-built spectrum.
struct SystemNoise {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53) * 2 - 1
    }
}
