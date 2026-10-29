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

/// Runs `x` through `process` in uneven buffers, as audio threads deliver them.
private func feed(_ x: [Float], _ process: (UnsafeMutableBufferPointer<Float>) -> Void) -> [Float] {
    var y = x
    let sizes = [480, 37, 1, 1000, 256, 3]
    y.withUnsafeMutableBufferPointer { b in
        var i = 0, k = 0
        while i < b.count {
            let n = min(sizes[k % sizes.count], b.count - i)
            process(UnsafeMutableBufferPointer(rebasing: b[i..<(i + n)]))
            i += n
            k += 1
        }
    }
    return y
}

private func run(_ reducer: SpectralNoiseReducer, _ x: [Float]) -> [Float] { feed(x, reducer.process) }

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

// MARK: - NoiseReducer (on/off, strength ramps, make-up gain)

private func runNR(_ nr: NoiseReducer, _ x: [Float]) -> [Float] { feed(x, nr.process) }

/// Mean power (dB) at `frequency` over the keyed-on stretches of a `syllables` signal that lie in
/// [from, to) seconds of the input, read from `y` delayed by `latency`. Each stretch is trimmed by
/// 50 ms at both ends so the reducer's frame-length smearing of the edges doesn't count.
private func keyedToneDb(_ y: [Float], latency: Int, from: Double, to: Double) -> Double {
    var total = 0.0, stretches = 0
    var start = (from / 0.5).rounded(.up) * 0.5
    while start + 0.5 <= to {
        let a = Int((start + 0.05) * fs) + latency, b = Int((start + 0.25) * fs) + latency
        total += TestSignals.power(of: y[a..<b], at: 1000, sampleRate: fs)
        stretches += 1
        start += 0.5
    }
    return 10 * log10(total / Double(stretches))
}

@Test func offIsBitExact() {
    let nr = NoiseReducer()
    let x = noise(seconds: 0.5, rms: 0.1, seed: 20)
    let y = runNR(nr, x)
    #expect(zip(x, y).allSatisfy { $0.bitPattern == $1.bitPattern })
}

@Test func offAfterOnSettlesToBitExact() {
    let nr = NoiseReducer()
    nr.update(NoiseReductionSettings(enabled: true, strength: 0.5))
    _ = runNR(nr, noise(seconds: 1, rms: 0.1, seed: 21))
    nr.update(NoiseReductionSettings(enabled: false, strength: 0.5))
    _ = runNR(nr, noise(seconds: 0.1, rms: 0.1, seed: 22))
    let x = noise(seconds: 0.5, rms: 0.1, seed: 23)
    let y = runNR(nr, x)
    #expect(zip(x, y).allSatisfy { $0.bitPattern == $1.bitPattern })
}

@Test func togglingHasNoStep() {
    // Enable at 1 s, disable at 3 s; a steady tone over noise, so the reducer is in the same
    // state before, during and after each fade.
    let x = mix(tone(seconds: 4, amplitude: amplitude(10, over: 0.1), frequency: 1000), noise(seconds: 4, rms: 0.1, seed: 24))
    let nr = NoiseReducer()
    var y: [Float] = []
    for (from, to, enabled) in [(0.0, 1.0, false), (1.0, 3.0, true), (3.0, 4.0, false)] {
        nr.update(NoiseReductionSettings(enabled: enabled, strength: 0.5))
        y += runNR(nr, Array(x[Int(from * fs)..<Int(to * fs)]))
    }
    func largestStep(_ range: Range<Int>) -> Float {
        range.dropFirst().map { abs(y[$0] - y[$0 - 1]) }.max()!
    }
    let fade = Int(0.03 * fs)
    for toggle in [Int(1.0 * fs), Int(3.0 * fs)] {
        let around = largestStep((toggle - 10)..<(toggle + fade + 10))
        let elsewhere = max(largestStep(Int(0.2 * fs)..<(toggle - 100)), largestStep((toggle + fade + 100)..<(toggle + Int(0.5 * fs))))
        #expect(around <= 1.5 * elsewhere, "toggle at \(Double(toggle) / fs) s: \(around) vs \(elsewhere)")
    }
}

@Test func makeUpKeepsTheVoiceLevel() {
    let nr = NoiseReducer()
    nr.update(NoiseReductionSettings(enabled: true, strength: 0.5))
    let x = mix(syllables(seconds: 8, amplitude: amplitude(6, over: 0.1)), noise(seconds: 8, rms: 0.1, seed: 25))
    let y = runNR(nr, x)
    let l = SpectralNoiseReducer().latency
    let change = keyedToneDb(y, latency: l, from: 3, to: 7.5) - keyedToneDb(x, latency: 0, from: 3, to: 7.5)
    #expect(abs(change) <= 2, "\(change) dB (make-up \(nr.makeupDb) dB)")
}

@Test func makeUpNeverLiftsTheNoiseBack() {
    let x = noise(seconds: 6, rms: 0.1, seed: 26)
    for (strength, limit) in [(0.0, -5.0), (0.5, -10.0), (1.0, -15.0)] {
        let nr = NoiseReducer()
        nr.update(NoiseReductionSettings(enabled: true, strength: strength))
        let y = runNR(nr, x)
        let l = SpectralNoiseReducer().latency
        let change = levelDb(y[(3 * Int(fs) + l)..<(5 * Int(fs) + l)]) - levelDb(x[(3 * Int(fs))..<(5 * Int(fs))])
        #expect(change <= limit, "strength \(strength): \(change) dB")
    }
}

@Test func aStrongToneIsNotColoured() {
    let x = mix(syllables(seconds: 6, amplitude: amplitude(30, over: 0.1)), noise(seconds: 6, rms: 0.1, seed: 27))
    for strength in [0.0, 0.5, 1.0] {
        let nr = NoiseReducer()
        nr.update(NoiseReductionSettings(enabled: true, strength: strength))
        let y = runNR(nr, x)
        let l = SpectralNoiseReducer().latency
        let change = keyedToneDb(y, latency: l, from: 2.5, to: 5.5) - keyedToneDb(x, latency: 0, from: 2.5, to: 5.5)
        #expect(abs(change) <= 0.5, "strength \(strength): \(change) dB")
    }
}

@Test func labelsAndAvailability() {
    #expect(NoiseReductionSettings(strength: 0.2).label == "Light")
    #expect(NoiseReductionSettings(strength: 0.5).label == "Medium")
    #expect(NoiseReductionSettings(strength: 0.9).label == "Strong")
    for mode in [DemodMode.am, .nfm, .usb, .lsb, .cw] { #expect(NoiseReductionSettings.isAvailable(for: mode)) }
    #expect(!NoiseReductionSettings.isAvailable(for: .wfm))
}

@Test func settingsRoundTrip() throws {
    let settings = NoiseReductionSettings(enabled: true, strength: 0.7)
    let decoded = try JSONDecoder().decode(NoiseReductionSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded == settings)
    #expect(NoiseReductionSettings() == NoiseReductionSettings(enabled: false, strength: 0.5))
}

@Test func voiceLossDoesNotCountTheHissRemoved() {
    // A tone only 3 dB over the noise: the hiss the reducer takes off is most of the frame's power,
    // but the voice itself loses very little. (Measured over all bins it read 1.7 dB, which make-up
    // would add to the voice as +1.3 dB.)
    let reducer = SpectralNoiseReducer()
    reducer.strength = 0.5
    _ = run(reducer, mix(syllables(seconds: 8, amplitude: amplitude(3, over: 0.1)), noise(seconds: 8, rms: 0.1, seed: 9)))
    #expect(reducer.voiceLossDb < 0.5, "\(reducer.voiceLossDb) dB")
}

/// A clean 317 Hz tone with a whisper of noise: its sample-to-sample steps are tiny, so any
/// discontinuity in the output shows up.
private func cleanTone(seconds: Double) -> [Float] {
    mix(tone(seconds: seconds, amplitude: 0.45, frequency: 317), noise(seconds: seconds, rms: 0.003, seed: 30))
}

private func largestStep(_ y: [Float], _ range: Range<Int>) -> Float {
    range.dropFirst().map { abs(y[$0] - y[$0 - 1]) }.max()!
}

private func rmsDb(_ y: [Float], _ start: Int, _ count: Int = 128) -> Double { levelDb(y[start..<(start + count)]) }

@Test func turningOnFromIdleHasNoStepOrDip() {
    let x = cleanTone(seconds: 3)
    let nr = NoiseReducer()
    let toggle = Int(fs) + 38      // a quarter period (38 samples) past a zero crossing: the tone is at its peak
    var y = runNR(nr, Array(x[0..<toggle]))
    nr.update(NoiseReductionSettings(enabled: true, strength: 0.5))
    y += runNR(nr, Array(x[toggle...]))
    let l = SpectralNoiseReducer().latency
    // No step beyond what the input itself has (the reducer is silent for `latency` samples).
    let inputStep = largestStep(x, 1000..<(2 * Int(fs)))
    let around = largestStep(y, (toggle - 10)..<(toggle + l + Int(0.03 * fs) + 400))
    #expect(around <= 1.5 * inputStep, "around \(around) vs input \(inputStep)")
    // No dip while the reducer fills: until the wet fade starts the output is the dry input.
    let dip = stride(from: toggle, to: toggle + l + 128, by: 128).map { rmsDb(y, $0) - rmsDb(x, $0) }.min()!
    #expect(dip >= -3, "dip \(dip) dB")
}

@Test func resetWhileOnHasNoDropoutOrStep() {
    let x = cleanTone(seconds: 4)
    let nr = NoiseReducer()
    nr.update(NoiseReductionSettings(enabled: true, strength: 0.5))
    let at = Int(2.5 * fs) + 38, l = SpectralNoiseReducer().latency      // tone at its peak
    var y = runNR(nr, Array(x[0..<at]))
    nr.reset()
    y += runNR(nr, Array(x[at...]))
    let inputStep = largestStep(x, 1000..<(3 * Int(fs)))
    let around = largestStep(y, (at - 10)..<(at + l + Int(0.2 * fs)))
    #expect(around <= 1.5 * inputStep, "around \(around) vs input \(inputStep)")
    // The output goes to the dry path and back, never to silence: between the reset and the fade
    // back to wet (30 ms + latency) it stays within 3 dB of the level it had before, or of the
    // input if that is lower.
    let wetBefore = rmsDb(y, at - 2048, 2048)
    let floorDb = min(wetBefore, rmsDb(x, at - 2048, 2048)) - 3
    let low = stride(from: at, to: at + Int(0.03 * fs) + l, by: 128).map { rmsDb(y, $0) }.min()!
    #expect(low >= floorDb, "lowest 128-sample level \(low) dB vs floor \(floorDb) dB (before the reset \(wetBefore) dB)")
}

@Test func turningOnAgainKeepsTheNoiseEstimate() {
    // A tone 6 dB over the noise, keyed in syllables. NR on for 4 s, off for 1 s, then on again
    // 50 ms into a syllable (5.0–5.3 s). A cold noise tracker takes the first frames' power, voice
    // and all, for noise and ducks the rest of that syllable.
    let x = mix(syllables(seconds: 7, amplitude: amplitude(6, over: 0.1)), noise(seconds: 7, rms: 0.1, seed: 31))
    let nr = NoiseReducer()
    let on = NoiseReductionSettings(enabled: true, strength: 0.5), off = NoiseReductionSettings(enabled: false, strength: 0.5)
    let offAt = 4 * Int(fs), onAt = Int(5.05 * fs)
    nr.update(on)
    var y = runNR(nr, Array(x[0..<offAt]))
    nr.update(off)
    y += runNR(nr, Array(x[offAt..<onAt]))
    nr.update(on)
    y += runNR(nr, Array(x[onAt...]))
    let l = SpectralNoiseReducer().latency
    // The rest of the syllable once the wet path is fully in (latency + 30 ms fade, + 10 ms).
    let a = onAt + Int(0.04 * fs), b = Int(5.28 * fs)
    let change = toneDb(y[(a + l)..<(b + l)]) - toneDb(x[a..<b])
    #expect(change >= -2, "the syllable after turning NR on again: \(change) dB")
}

@Test func aNaNOrInfinityInTheInputDoesNotStick() {
    // A NaN and an infinity in settled noise: the frames holding them come out as they went in, and
    // once they have passed the output is finite and still reduced.
    var x = noise(seconds: 6, rms: 0.1, seed: 32)
    x[3 * Int(fs) + 100] = .nan
    x[Int(3.2 * fs) + 7] = .infinity
    let reducer = SpectralNoiseReducer()
    reducer.strength = 0.5
    let y = run(reducer, x)
    let l = reducer.latency
    let after = Int(3.3 * fs) + l
    #expect(y[after...].allSatisfy { $0.isFinite })
    #expect(reducer.voiceLossDb.isFinite)
    let before = reductionDb(x, y, latency: l, from: 2.5, to: 3), later = reductionDb(x, y, latency: l, from: 3.5, to: 5.9)
    #expect((-16.0 ... -11.0).contains(later), "reduction \(later) dB after, \(before) dB before")

    let nr = NoiseReducer()
    nr.update(NoiseReductionSettings(enabled: true, strength: 0.5))
    let z = runNR(nr, x)
    #expect(z[after...].allSatisfy { $0.isFinite })
    #expect(nr.makeupDb.isFinite)
}

@Test func aHugeToneOverQuietNoiseGivesNoNaNs() {
    // A 1e6 burst (framed power 5e11) over noise just above digital silence: the a-posteriori SNR
    // reaches ~1e21, past what the exponential integral's rational approximation can square.
    let x = mix(noise(seconds: 6, rms: 2e-4, seed: 33),
                [Float](repeating: 0, count: 3 * Int(fs)) + tone(seconds: 0.2, amplitude: 1e6, frequency: 1000)
                    + [Float](repeating: 0, count: Int(2.8 * fs)))
    let reducer = SpectralNoiseReducer()
    reducer.strength = 0.5
    let y = run(reducer, x)
    #expect(y.allSatisfy { $0.isFinite })
    #expect(reducer.voiceLossDb.isFinite)
    let later = reductionDb(x, y, latency: reducer.latency, from: 3.6, to: 5.9)
    #expect((-16.0 ... -11.0).contains(later), "reduction \(later) dB after the burst")
}
