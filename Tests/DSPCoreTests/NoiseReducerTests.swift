import Testing
import Foundation
@testable import DSPCore

private let fs = 48_000.0

/// Seeded real white noise.
private func noise(seconds: Double, rms: Double, seed: UInt64) -> [Float] {
    TestSignals.noise(count: Int(seconds * fs), sigma: rms, seed: seed).map(\.real)
}

private func tone(seconds: Double, amplitude: Double, frequency: Double) -> [Float] {
    (0..<Int(seconds * fs)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / fs)) }
}

/// A voice-like tone: keyed in syllables, on 0.3 s then off 0.2 s. A steady tone would be learnt as
/// noise by the minimum-statistics tracker, as a steady carrier is.
private func syllables(seconds: Double, amplitude: Double, frequency: Double = 1000) -> [Float] {
    (0..<Int(seconds * fs)).map { i in
        let t = Double(i) / fs
        return t.truncatingRemainder(dividingBy: 0.5) < 0.3 ? Float(amplitude * sin(2 * .pi * frequency * t)) : 0
    }
}

/// Amplitude of a sine whose power is `db` above white noise of `rms`.
private func amplitude(_ db: Double, over rms: Double) -> Double { rms * sqrt(2) * pow(10, db / 20) }

/// Sample-wise sum of equal-length signals.
private func mix(_ signals: [Float]...) -> [Float] {
    signals.dropFirst().reduce(signals[0]) { zip($0, $1).map { $0 + $1 } }
}

/// Runs `x` through `reducer` in uneven buffers, as audio threads deliver them.
private func run(_ reducer: SpectralNoiseReducer, _ x: [Float]) -> [Float] {
    var y = x
    let sizes = [480, 37, 1, 1000, 256, 3]
    y.withUnsafeMutableBufferPointer { b in
        var i = 0, k = 0
        while i < b.count {
            let n = min(sizes[k % sizes.count], b.count - i)
            reducer.process(UnsafeMutableBufferPointer(rebasing: b[i..<(i + n)]))
            i += n
            k += 1
        }
    }
    return y
}

private func levelDb(_ x: ArraySlice<Float>) -> Double {
    10 * log10(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count))
}

private func toneDb(_ x: ArraySlice<Float>, at frequency: Double = 1000) -> Double {
    10 * log10(TestSignals.power(of: x, at: frequency, sampleRate: fs))
}

/// Input samples [from, to) seconds and the output samples they became.
private func aligned(_ x: [Float], _ y: [Float], latency: Int, from: Double, to: Double)
    -> (input: ArraySlice<Float>, output: ArraySlice<Float>) {
    let a = Int(from * fs), b = Int(to * fs)
    return (x[a..<b], y[(a + latency)..<(b + latency)])
}

private func reductionDb(_ x: [Float], _ y: [Float], latency: Int, from: Double, to: Double) -> Double {
    let s = aligned(x, y, latency: latency, from: from, to: to)
    return levelDb(s.output) - levelDb(s.input)
}

@Test func latencyIsReportedExactly() {
    let reducer = SpectralNoiseReducer()
    var x = noise(seconds: 3, rms: 0.001, seed: 1)
    let at = 2 * Int(fs) + 123
    x[at] += 1
    let y = run(reducer, x)
    let peak = y.indices.max { abs(y[$0]) < abs(y[$1]) }!
    #expect(abs(peak - (at + reducer.latency)) <= 1)
    #expect(reducer.latency < Int(0.05 * fs))
}

@Test func gainNeverAmplifies() {
    let x = mix(noise(seconds: 3, rms: 0.1, seed: 2),
                tone(seconds: 3, amplitude: 0.3, frequency: 700),
                syllables(seconds: 3, amplitude: 0.3, frequency: 1500))
    for strength in [0.0, 0.5, 1.0] {
        let reducer = SpectralNoiseReducer()
        reducer.strength = strength
        let y = run(reducer, x)
        let block = Int(0.1 * fs)
        for a in stride(from: 0, to: x.count - reducer.latency - block, by: block) {
            let gain = levelDb(y[(a + reducer.latency)..<(a + reducer.latency + block)]) - levelDb(x[a..<(a + block)])
            #expect(gain <= 0.1, "strength \(strength), block at \(Double(a) / fs) s: \(gain) dB")
        }
    }
}

@Test func whiteNoiseIsReducedByAboutTheFloor() {
    let x = noise(seconds: 5, rms: 0.1, seed: 3)
    for (strength, band) in [(0.0, -10.0 ... -6.0), (0.5, -16.0 ... -11.0), (1.0, -22.0 ... -16.0)] {
        let reducer = SpectralNoiseReducer()
        reducer.strength = strength
        let y = run(reducer, x)
        let reduction = reductionDb(x, y, latency: reducer.latency, from: 2, to: 4.95)
        #expect(band.contains(reduction), "strength \(strength): \(reduction) dB")
    }
}

@Test func aVoiceLikeToneAboveTheNoisePasses() {
    let reducer = SpectralNoiseReducer()
    reducer.strength = 0.5
    let x = mix(syllables(seconds: 6, amplitude: amplitude(15, over: 0.1)), noise(seconds: 6, rms: 0.1, seed: 4))
    let y = run(reducer, x)
    let s = aligned(x, y, latency: reducer.latency, from: 2, to: 5.5)
    let change = toneDb(s.output) - toneDb(s.input)
    #expect(abs(change) <= 1.5, "\(change) dB")
}

@Test func digitalSilenceGivesSilenceAndNoNaNs() {
    let reducer = SpectralNoiseReducer()
    let y = run(reducer, [Float](repeating: 0, count: 2 * Int(fs)))
    #expect(y.allSatisfy { $0 == 0 })
    #expect(y.allSatisfy { $0.isFinite } && reducer.voiceLossDb.isFinite)
    #expect(reducer.voiceLossDb == 0)
}

@Test func noiseEstimateSurvivesDigitalSilence() {
    let reducer = SpectralNoiseReducer()
    reducer.strength = 0.5
    let n = noise(seconds: 6, rms: 0.1, seed: 5)
    let x = Array(n[0..<(3 * Int(fs))]) + [Float](repeating: 0, count: 5 * Int(fs)) + Array(n[(3 * Int(fs))...])
    let y = run(reducer, x)
    let before = reductionDb(x, y, latency: reducer.latency, from: 2.5, to: 3)
    let after = reductionDb(x, y, latency: reducer.latency, from: 8, to: 8.5)
    #expect(abs(after - before) <= 2, "before \(before) dB, after \(after) dB")
}

@Test func aCrashDoesNotDuckTheVoiceAfterIt() {
    let reducer = SpectralNoiseReducer()
    reducer.strength = 0.5
    var x = mix(syllables(seconds: 5, amplitude: amplitude(15, over: 0.1)), noise(seconds: 5, rms: 0.1, seed: 6))
    let crash = noise(seconds: 0.2, rms: 1, seed: 7)
    let at = 3 * Int(fs)
    for (i, v) in crash.enumerated() { x[at + i] += v }
    let y = run(reducer, x)
    let l = reducer.latency
    let before = toneDb(y[(Int(2.5 * fs) + l)..<(3 * Int(fs) + l)])
    let after = toneDb(y[(Int(3.5 * fs) + l)..<(4 * Int(fs) + l)])
    #expect(abs(after - before) <= 1, "before \(before) dB, after \(after) dB")
}

@Test func voiceLossIsMeasuredOnSpeechFramesOnly() {
    let quiet = SpectralNoiseReducer()
    quiet.strength = 0.5
    let n = noise(seconds: 5, rms: 0.1, seed: 8)
    var loudest: Float = 0
    for a in stride(from: 0, to: n.count, by: 4800) {
        _ = run(quiet, Array(n[a..<min(a + 4800, n.count)]))
        loudest = max(loudest, quiet.voiceLossDb)
    }
    #expect(loudest == 0)

    let voiced = SpectralNoiseReducer()
    voiced.strength = 0.5
    _ = run(voiced, mix(syllables(seconds: 5, amplitude: amplitude(15, over: 0.1)), noise(seconds: 5, rms: 0.1, seed: 9)))
    #expect(voiced.voiceLossDb > 0 && voiced.voiceLossDb < 6, "\(voiced.voiceLossDb) dB")
}

@Test func floorAndOverEstimateMapping() {
    #expect(SpectralNoiseReducer.floorDb(strength: 0) == -8)
    #expect(SpectralNoiseReducer.floorDb(strength: 0.5) == -14)
    #expect(SpectralNoiseReducer.floorDb(strength: 1) == -20)
    #expect(SpectralNoiseReducer.overEstimate(strength: 0) == 1)
    #expect(SpectralNoiseReducer.overEstimate(strength: 0.5) == 1.5)
    #expect(SpectralNoiseReducer.overEstimate(strength: 1) == 2)
}
