import Testing
import Foundation
@testable import Modems
import DSPCore

// All audio is 12 kHz box audio built from ModemTestSignals. SNRs follow ruling R7: signal power is
// the steady in-burst power of one signal (amplitude²/2 for a tone), noise is measured in 2.5 kHz,
// and `signalPower` is passed whenever the buffer holds several signals or silence.

private let fs = 12_000.0

/// Feeds `audio` to the tracker in chunks of `chunk` samples.
private func feed(_ tracker: SignalTracker, _ audio: ArraySlice<Float>, chunk: Int = 1_000) {
    var start = audio.startIndex
    while start < audio.endIndex {
        let end = min(start + chunk, audio.endIndex)
        audio[start..<end].withUnsafeBufferPointer { tracker.process($0) }
        start = end
    }
}

private func feed(_ tracker: SignalTracker, _ audio: [Float], chunk: Int = 1_000) {
    feed(tracker, audio[...], chunk: chunk)
}

/// Element-wise sum of equally long buffers.
private func mix(_ parts: [Float]...) -> [Float] {
    var out = parts[0]
    for p in parts.dropFirst() {
        precondition(p.count == out.count)
        for i in out.indices { out[i] += p[i] }
    }
    return out
}

/// Phase-continuous FSK between `low` and `high` Hz, one bit per `bitSeconds`. `bits` nil gives
/// strict alternation (an RYRY-like worst case with discrete keying lines); otherwise bits are random.
private func fsk(low: Double, high: Double, bitSeconds: Double, seconds: Double, amplitude: Float,
                 randomBitsSeed: UInt64? = nil) -> [Float] {
    let n = Int(seconds * fs)
    var out = [Float](repeating: 0, count: n)
    var phase = 0.0
    var state = randomBitsSeed ?? 0
    var bit = false
    var currentBitIndex = -1
    for i in 0..<n {
        let bitIndex = Int(Double(i) / fs / bitSeconds)
        if bitIndex != currentBitIndex {
            currentBitIndex = bitIndex
            if randomBitsSeed != nil {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                bit = (state >> 33) & 1 == 1
            } else {
                bit = bitIndex % 2 == 1
            }
        }
        phase += 2 * Double.pi * (bit ? high : low) / fs
        out[i] = amplitude * Float(sin(phase))
    }
    return out
}

// MARK: - Brief tests

@Test func findsThreeCarriers() {
    let a: Float = 0.3
    let p = Double(a * a) / 2
    let clean = mix(ModemTestSignals.tone(700, seconds: 3, amplitude: a),
                    ModemTestSignals.tone(1_500, seconds: 3, amplitude: a),
                    ModemTestSignals.tone(2_400, seconds: 3, amplitude: a))
    let audio = ModemTestSignals.awgn(clean, snrDb: 10, seed: 11, signalPower: p)
    let tracker = SignalTracker()
    feed(tracker, audio)

    let tracks = tracker.tracks
    #expect(tracks.count == 3)
    guard tracks.count == 3 else { return }
    for (track, hz) in zip(tracks, [700.0, 1_500, 2_400]) {
        #expect(abs(track.frequencyHz - hz) < 1, "track at \(track.frequencyHz) Hz, expected \(hz)")
        #expect(abs(track.snrDb - 10) < 1, "SNR \(track.snrDb) dB at \(hz) Hz, expected 10")
        #expect(!track.isFSKPair)
        // A plain carrier must not report sidebands: the classifier would read them as PSK.
        #expect(track.peakOffsetsHz.isEmpty, "spurious offsets \(track.peakOffsetsHz) at \(hz) Hz")
        #expect(track.bandwidthHz < 15, "bandwidth \(track.bandwidthHz) Hz for a pure tone")
        #expect(!track.isQuiet)
    }
    #expect(Set(tracks.map(\.id)).count == 3)
}

/// BPSK31 idle is two tones at ±15.625 Hz (cosine-shaped reversals). Task 6 provides the encoder;
/// this is the plan's two-tone approximation, at several SNRs.
@Test(arguments: [10.0, 0.0, -10.0])
func psk31SidebandsDoNotSpawnTracks(_ snrDb: Double) {
    let a: Float = 0.25
    let clean = mix(ModemTestSignals.tone(1_484.4, seconds: 3, amplitude: a),
                    ModemTestSignals.tone(1_515.6, seconds: 3, amplitude: a))
    // Constant-envelope idle: in-burst power is the sum of both tones.
    let audio = ModemTestSignals.awgn(clean, snrDb: snrDb, seed: 21, signalPower: 2 * Double(a * a) / 2)
    let tracker = SignalTracker()
    feed(tracker, audio)

    let tracks = tracker.tracks
    #expect(tracks.count == 1, "got \(tracks.map(\.frequencyHz)) at \(snrDb) dB")
    guard let t = tracks.first else { return }
    #expect(abs(t.frequencyHz - 1_500) < 3)
    #expect(!t.isFSKPair)
    #expect(abs(t.snrDb - Float(snrDb)) < 1.5, "SNR \(t.snrDb) dB, expected \(snrDb)")
    // The classifier looks for sidebands at ±15.6 ± 2 Hz.
    #expect(t.peakOffsetsHz.contains { abs($0 + 15.6) < 2 })
    #expect(t.peakOffsetsHz.contains { abs($0 - 15.6) < 2 })
}

@Test func rttyPairIsOneTrack() {
    let a: Float = 0.5
    let audio = ModemTestSignals.awgn(
        fsk(low: 1_415, high: 1_585, bitSeconds: 0.022, seconds: 3, amplitude: a),
        snrDb: 10, seed: 31, signalPower: Double(a * a) / 2)
    let tracker = SignalTracker()
    feed(tracker, audio)

    let tracks = tracker.tracks
    #expect(tracks.count == 1, "got \(tracks.map { ($0.frequencyHz, $0.isFSKPair) })")
    guard let t = tracks.first else { return }
    #expect(t.isFSKPair)
    #expect(abs(t.frequencyHz - 1_500) < 3)
    #expect(abs(t.snrDb - 10) < 1.5, "SNR \(t.snrDb) dB, expected 10")
    #expect(t.bandwidthHz > 150)
}

@Test func rttyRandomDataIsOneTrack() {
    let a: Float = 0.5
    for seed: UInt64 in [1, 2, 3] {
        let audio = ModemTestSignals.awgn(
            fsk(low: 2_015, high: 2_185, bitSeconds: 0.022, seconds: 4, amplitude: a, randomBitsSeed: seed),
            snrDb: 0, seed: 40 + seed, signalPower: Double(a * a) / 2)
        let tracker = SignalTracker()
        feed(tracker, audio)
        let tracks = tracker.tracks
        #expect(tracks.count == 1, "seed \(seed): \(tracks.map { ($0.frequencyHz, $0.isFSKPair) })")
        guard let t = tracks.first else { continue }
        #expect(t.isFSKPair)
        #expect(abs(t.frequencyHz - 2_100) < 3, "seed \(seed): \(t.frequencyHz) Hz")
        #expect(abs(t.snrDb - 0) < 1.5, "seed \(seed): SNR \(t.snrDb) dB, expected 0")
    }
}

@Test func weakNextToStrong() {
    let strongA: Float = 0.5
    let weakA = strongA * Float(pow(10, -30.0 / 20))       // 30 dB below
    let clean = mix(ModemTestSignals.tone(1_000, seconds: 3, amplitude: strongA),
                    ModemTestSignals.tone(1_060, seconds: 3, amplitude: weakA))
    let audio = ModemTestSignals.awgn(clean, snrDb: 25, seed: 51, signalPower: Double(strongA * strongA) / 2)
    let tracker = SignalTracker()
    feed(tracker, audio)

    let tracks = tracker.tracks
    #expect(tracks.count == 2, "got \(tracks.map(\.frequencyHz))")
    guard tracks.count == 2 else { return }
    #expect(abs(tracks[0].frequencyHz - 1_000) < 1)
    #expect(abs(tracks[1].frequencyHz - 1_060) < 1)
    #expect(abs(tracks[0].snrDb - 25) < 1, "strong SNR \(tracks[0].snrDb)")
    #expect(abs(tracks[1].snrDb - -5) < 1.5, "weak SNR \(tracks[1].snrDb)")
    #expect(tracks[0].peakOffsetsHz.isEmpty, "strong carrier offsets \(tracks[0].peakOffsetsHz)")
}

@Test func driftKeepsID() {
    // 1 Hz/s sweep from 1200 to 1230 Hz over 30 s, phase continuous.
    let n = Int(30 * fs)
    var phase = 0.0
    var clean = [Float](repeating: 0, count: n)
    for i in 0..<n {
        phase += 2 * Double.pi * (1_200 + Double(i) / fs) / fs
        clean[i] = 0.5 * Float(sin(phase))
    }
    let audio = ModemTestSignals.awgn(clean, snrDb: 10, seed: 61, signalPower: 0.125)
    let tracker = SignalTracker()
    feed(tracker, audio[0..<Int(2 * fs)])
    #expect(tracker.tracks.count == 1)
    guard let id = tracker.tracks.first?.id else { return }

    for second in 2..<30 {
        feed(tracker, audio[(second * Int(fs))..<((second + 1) * Int(fs))])
        let tracks = tracker.tracks
        #expect(tracks.count == 1 && tracks[0].id == id, "at \(second + 1) s: \(tracks.map { ($0.id, $0.frequencyHz) })")
        if let t = tracks.first {
            // The averaged spectrum lags a moving tone by well under 2 Hz at 1 Hz/s.
            #expect(abs(t.frequencyHz - (1_200 + Double(second + 1))) < 2, "at \(second + 1) s: \(t.frequencyHz) Hz")
        }
    }
    let end = tracker.tracks.first
    #expect(end?.id == id)
    #expect(abs((end?.frequencyHz ?? 0) - 1_230) < 2)
}

@Test(arguments: [UInt64(71), 72, 73])
func quietThenRemoved(_ seed: UInt64) {
    let a: Float = 0.5
    let burst = ModemTestSignals.tone(1_700, seconds: 2, amplitude: a)
    let silence = [Float](repeating: 0, count: Int(121 * fs))
    // The buffer is mostly silence, so the in-burst power is passed explicitly (R7).
    let audio = ModemTestSignals.awgn(burst + silence, snrDb: 10, seed: seed, signalPower: Double(a * a) / 2)
    let tracker = SignalTracker()
    let s = { (seconds: Double) in Int(seconds * fs) }

    feed(tracker, audio[0..<s(2)])
    #expect(tracker.tracks.count == 1)
    guard let id = tracker.tracks.first?.id else { return }
    #expect(tracker.tracks[0].isQuiet == false)

    var fed = s(2)
    func advance(toSilenceSeconds t: Double) {
        let target = s(2 + t)
        while fed < target {
            let end = min(fed + s(1), target)
            feed(tracker, audio[fed..<end])
            fed = end
            // Noise must never spawn a second track.
            #expect(tracker.tracks.count <= 1)
            #expect(tracker.tracks.allSatisfy { $0.id == id })
        }
    }

    advance(toSilenceSeconds: 19)
    #expect(tracker.tracks.first?.id == id)
    #expect(tracker.tracks.first?.isQuiet == false, "quiet too early (19 s of silence)")

    advance(toSilenceSeconds: 21)
    #expect(tracker.tracks.first?.id == id)
    #expect(tracker.tracks.first?.isQuiet == true, "not quiet after 21 s of silence")

    advance(toSilenceSeconds: 119)
    #expect(tracker.tracks.first?.id == id, "removed too early (119 s of silence)")
    #expect(tracker.tracks.first?.isQuiet == true)

    advance(toSilenceSeconds: 121)
    #expect(tracker.tracks.isEmpty, "still present after 121 s of silence")
}

@Test(arguments: [UInt64(1), 2, 3, 4, 5, 6])
func noiseOnlyMakesNoTracks(_ seed: UInt64) {
    let audio = ModemTestSignals.noise(seconds: 30, seed: seed)
    let tracker = SignalTracker()
    var start = 0
    while start < audio.count {
        let end = min(start + 3_000, audio.count)
        feed(tracker, audio[start..<end])
        start = end
        #expect(tracker.tracks.isEmpty, "seed \(seed): false tracks \(tracker.tracks.map(\.frequencyHz)) at \(Double(end) / fs) s")
        if !tracker.tracks.isEmpty { return }
    }
}

// MARK: - Calibration and plumbing

@Test(arguments: [20.0, 0.0, -15.0])
func snrIsCalibratedTo2500HzBandwidth(_ snrDb: Double) {
    let a: Float = 0.5
    let audio = ModemTestSignals.awgn(ModemTestSignals.tone(1_234.5, seconds: 4, amplitude: a),
                                      snrDb: snrDb, seed: 81, signalPower: Double(a * a) / 2)
    let tracker = SignalTracker()
    feed(tracker, audio)
    #expect(tracker.tracks.count == 1)
    guard let t = tracker.tracks.first else { return }
    #expect(abs(t.frequencyHz - 1_234.5) < 1)
    #expect(abs(t.snrDb - Float(snrDb)) < 1, "SNR \(t.snrDb) dB, expected \(snrDb)")
}

@Test func outOfBandSignalsAreIgnored() {
    let a: Float = 0.3
    let p = Double(a * a) / 2
    let clean = mix(ModemTestSignals.tone(200, seconds: 3, amplitude: a),
                    ModemTestSignals.tone(3_500, seconds: 3, amplitude: a),
                    ModemTestSignals.tone(1_000, seconds: 3, amplitude: a))
    let tracker = SignalTracker()
    feed(tracker, ModemTestSignals.awgn(clean, snrDb: 10, seed: 91, signalPower: p))
    #expect(tracker.tracks.map { $0.frequencyHz.rounded() } == [1_000])
}

@Test func chunkSizeDoesNotChangeResults() {
    let audio = ModemTestSignals.awgn(
        mix(ModemTestSignals.tone(900, seconds: 2, amplitude: 0.3), ModemTestSignals.tone(2_000, seconds: 2, amplitude: 0.3)),
        snrDb: 5, seed: 101, signalPower: 0.045)
    var results: [[Track]] = []
    for chunk in [1, 333, 4_096, audio.count] {
        let tracker = SignalTracker()
        feed(tracker, audio, chunk: chunk)
        #expect(tracker.samplesSeen == audio.count)
        results.append(tracker.tracks)
    }
    #expect(results[0].count == 2)
    #expect(results.allSatisfy { $0 == results[0] })
}

@Test func spectrumAndResetPlumbing() {
    let tracker = SignalTracker()
    #expect(abs(tracker.binHz - 12_000.0 / 4_096) < 1e-12)
    #expect(SignalTracker.quietAfterSeconds == 20)
    #expect(SignalTracker.removeAfterSeconds == 120)
    feed(tracker, ModemTestSignals.awgn(ModemTestSignals.tone(1_500, seconds: 2, amplitude: 0.5), snrDb: 10, seed: 111))
    let first = tracker.tracks
    #expect(first.count == 1)
    let db = tracker.averagedSpectrumDb
    #expect(db.count == 4_096 / 2 + 1)
    // The averaged spectrum peaks at the tone's bin.
    let band = Int(1_000 / tracker.binHz)..<Int(2_000 / tracker.binHz)
    let peakBin = band.max { db[$0] < db[$1] } ?? 0
    #expect(abs(Double(peakBin) * tracker.binHz - 1_500) < tracker.binHz)
    #expect(first[0].firstSeenSample > 0 && first[0].firstSeenSample <= first[0].lastActiveSample)
    #expect(first[0].lastActiveSample <= tracker.samplesSeen)

    tracker.reset()
    #expect(tracker.tracks.isEmpty)
    #expect(tracker.samplesSeen == 0)
    // Ids are never reused after a reset, so stale text can't attach to a new signal.
    feed(tracker, ModemTestSignals.awgn(ModemTestSignals.tone(1_500, seconds: 2, amplitude: 0.5), snrDb: 10, seed: 112))
    #expect(tracker.tracks.count == 1)
    #expect((tracker.tracks.first?.id ?? -1) > first[0].id)
}

@Test func quietTrackRevivesWithSameID() {
    let a: Float = 0.5
    let tone = ModemTestSignals.tone(1_700, seconds: 3, amplitude: a)
    let gap = [Float](repeating: 0, count: Int(25 * fs))
    let audio = ModemTestSignals.awgn(tone + gap + tone, snrDb: 10, seed: 121, signalPower: Double(a * a) / 2)
    let tracker = SignalTracker()
    feed(tracker, audio[0..<Int(3 * fs)])
    guard let id = tracker.tracks.first?.id else { Issue.record("tone not tracked"); return }

    feed(tracker, audio[Int(3 * fs)..<Int(28 * fs)])
    #expect(tracker.tracks.count == 1)
    #expect(tracker.tracks.first?.isQuiet == true)
    // Noise during the gap must not drag the quiet track's frequency.
    #expect(abs((tracker.tracks.first?.frequencyHz ?? 0) - 1_700) < 1)
    let quietSince = tracker.tracks.first?.lastActiveSample ?? 0

    feed(tracker, audio[Int(28 * fs)...])
    #expect(tracker.tracks.count == 1)
    guard let t = tracker.tracks.first else { return }
    #expect(t.id == id)
    #expect(!t.isQuiet)
    #expect(t.lastActiveSample > quietSince)
    #expect(abs(t.frequencyHz - 1_700) < 1)
}

/// On/off keyed CW at 20 WPM with 3 s pauses between overs: one steady track that never goes quiet.
@Test func keyedCWIsOneLiveTrack() {
    let rate = fs
    let unit = Int(MorseCode.dotSeconds(wpm: 20) * rate)
    var keyed: [Bool] = []
    while keyed.count < Int(40 * rate) {
        for e in MorseCode.timeline(for: "CQ CQ DE TEST K") { keyed += Array(repeating: e.on, count: e.units * unit) }
        keyed += Array(repeating: false, count: Int(3 * rate))
    }
    // 4 ms linear key ramps, like a real transmitter's click filter.
    let ramp = Int(0.004 * rate)
    var envelope = [Float](repeating: 0, count: keyed.count)
    var level: Float = 0
    for i in keyed.indices {
        level = keyed[i] ? min(1, level + 1 / Float(ramp)) : max(0, level - 1 / Float(ramp))
        envelope[i] = level
    }
    let a: Float = 0.5
    let clean = envelope.enumerated().map { i, e in a * e * Float(sin(2 * Double.pi * 700 * Double(i) / rate)) }
    // Key-down power is the in-burst power (R7).
    let audio = ModemTestSignals.awgn(clean, snrDb: 5, seed: 131, signalPower: Double(a * a) / 2)
    let tracker = SignalTracker()
    feed(tracker, audio[0..<Int(3 * rate)])
    #expect(tracker.tracks.count == 1)
    guard let id = tracker.tracks.first?.id else { return }
    var second = 3
    while (second + 1) * Int(rate) <= audio.count {
        feed(tracker, audio[(second * Int(rate))..<((second + 1) * Int(rate))])
        second += 1
        let tracks = tracker.tracks
        #expect(tracks.count == 1 && tracks[0].id == id, "at \(second) s: \(tracks.map { ($0.id, $0.frequencyHz) })")
        if let t = tracks.first {
            #expect(abs(t.frequencyHz - 700) < 1, "at \(second) s: \(t.frequencyHz) Hz")
            #expect(!t.isQuiet)
            #expect(!t.isFSKPair)
        }
    }
}

/// The floor is calibrated to the mean noise power per bin, so SNR readings are unbiased.
@Test func noiseFloorIsUnbiased() {
    let tracker = SignalTracker()
    let sigma = 0.05
    let w = WindowKind.hann.coefficients(count: 4_096)
    let s1 = Double(w.reduce(0, +)), s2 = Double(w.map { $0 * $0 }.reduce(0, +))
    // Mean noise power per bin with the tracker's scaling (a unit sine reads 1).
    let expected = 4 * sigma * sigma * s2 / (s1 * s1)
    let audio = ModemTestSignals.noise(seconds: 40, sigma: Float(sigma), seed: 141)
    let band = Int(300 / tracker.binHz) + 1..<Int(3_300 / tracker.binHz)
    var ratios: [Double] = []
    var start = 0
    while start < audio.count {
        feed(tracker, audio[start..<min(start + 2_048, audio.count)])
        start += 2_048
        guard start > 24_000 else { continue }
        let f = tracker.noiseFloor
        ratios.append(band.map { Double(f[$0]) }.reduce(0, +) / Double(band.count) / expected)
    }
    let mean = ratios.reduce(0, +) / Double(ratios.count)
    #expect(abs(10 * log10(mean)) < 0.1, "floor bias \(10 * log10(mean)) dB")
    #expect(ratios.allSatisfy { abs(10 * log10($0)) < 0.5 }, "per-frame floor range \(ratios.min()!)...\(ratios.max()!)")
}

// MARK: - Busy band (review fix round 1)

/// BPSK31 at `hz`: cosine-shaped reversals at 31.25 Bd. `reversalProbability` 1 is idle (two lines
/// at ±15.625 Hz); 0.5 is random data. `timingOffset` shifts the symbol clock, in symbols.
private func bpsk31(_ hz: Double, seconds: Double, amplitude: Float = 0.5, seed: UInt64,
                    reversalProbability: Double = 0.5, timingOffset: Double = 0, phase: Double = 0) -> [Float] {
    let n = Int(seconds * fs)
    let symbol = fs / 31.25
    var out = [Float](repeating: 0, count: n)
    var state = seed
    var sign: Float = 1
    var reversing = false
    var currentSymbol = Int.min
    for i in 0..<n {
        let t = Double(i) / symbol + timingOffset
        let s = Int(t.rounded(.down))
        if s != currentSymbol {
            if reversing { sign = -sign }
            currentSymbol = s
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            reversing = Double(state >> 11) / Double(1 << 53) < reversalProbability
        }
        let envelope: Float = reversing ? sign * Float(cos(Double.pi * (t - Double(s)))) : sign
        out[i] = amplitude * envelope * Float(cos(2 * Double.pi * hz * Double(i) / fs + phase))
    }
    return out
}

private func meanSquare(_ x: [Float]) -> Double { x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count) }

/// Mixes signals and adds noise for `snrDb` per signal, relative to the first signal's power.
private func scene(_ signals: [[Float]], snrDb: Double, seed: UInt64, referencePower: Double? = nil) -> [Float] {
    var x = signals[0]
    for s in signals.dropFirst() { for i in x.indices { x[i] += s[i] } }
    return ModemTestSignals.awgn(x, snrDb: snrDb, seed: seed, signalPower: referencePower ?? meanSquare(signals[0]))
}

private func expectTracks(_ tracker: SignalTracker, at expected: [Double], tolerance: Double = 3,
                          _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let tracks = tracker.tracks
    #expect(tracks.count == expected.count, "\(label): \(tracks.map { ($0.frequencyHz, $0.isFSKPair) })",
            sourceLocation: sourceLocation)
    guard tracks.count == expected.count else { return }
    for (t, hz) in zip(tracks, expected) {
        #expect(abs(t.frequencyHz - hz) < tolerance, "\(label): \(t.frequencyHz) Hz, expected \(hz)",
                sourceLocation: sourceLocation)
    }
}

@Test(arguments: [(1.0, 10.0), (0.5, 10.0), (0.5, 0.0)])
func busyPSKBandStaysSeparate(_ reversalProbability: Double, _ snrDb: Double) {
    let centres = (0..<7).map { 800 + 55 * Double($0) }
    let signals = centres.enumerated().map { i, hz in
        bpsk31(hz, seconds: 6, seed: UInt64(i) + 1, reversalProbability: reversalProbability,
               timingOffset: Double(i) * 0.37, phase: Double(i))
    }
    let tracker = SignalTracker()
    feed(tracker, scene(signals, snrDb: snrDb, seed: 151))
    expectTracks(tracker, at: centres, "p=\(reversalProbability) snr=\(snrDb)")
    #expect(!tracker.tracks.contains { $0.isFSKPair })
}

@Test(arguments: [160.0, 170, 180])
func twoPSKSignalsNear170HzAreNotRTTY(_ spacing: Double) {
    for (p, offset) in [(1.0, 0.0), (1.0, 0.5), (0.5, 0.0)] {
        for snr in [10.0, 0.0] {
            let a = bpsk31(1_200, seconds: 5, seed: 3, reversalProbability: p)
            let b = bpsk31(1_200 + spacing, seconds: 5, seed: 4, reversalProbability: p, timingOffset: offset, phase: 1)
            let tracker = SignalTracker()
            feed(tracker, scene([a, b], snrDb: snr, seed: 161))
            expectTracks(tracker, at: [1_200, 1_200 + spacing], "spacing \(spacing) p=\(p) offset \(offset) snr \(snr)")
            #expect(!tracker.tracks.contains { $0.isFSKPair })
        }
    }
}

@Test func weakNeighboursBesideRTTYSurvive() {
    let rttyA: Float = 0.5
    let rttyPower = Double(rttyA * rttyA) / 2
    let rtty = fsk(low: 1_415, high: 1_585, bitSeconds: 0.022, seconds: 5, amplitude: rttyA, randomBitsSeed: 9)
    // Neighbours 20 dB below a +20 dB RTTY signal, i.e. at 0 dB.
    let weak = rttyA * Float(pow(10, -20.0 / 20))
    let cases: [(String, [Float], Double)] = [
        ("PSK31 mark+80", bpsk31(1_665, seconds: 5, amplitude: weak * 1.414, seed: 5), 1_665),
        ("PSK31 mark+120", bpsk31(1_705, seconds: 5, amplitude: weak * 1.414, seed: 6), 1_705),
        ("PSK31 mark+170", bpsk31(1_755, seconds: 5, amplitude: weak * 1.414, seed: 7), 1_755),
        ("PSK31 space-120", bpsk31(1_295, seconds: 5, amplitude: weak * 1.414, seed: 8), 1_295),
        ("CW mark+80", ModemTestSignals.tone(1_665, seconds: 5, amplitude: weak), 1_665),
    ]
    for (label, neighbour, hz) in cases {
        let tracker = SignalTracker()
        feed(tracker, scene([rtty, neighbour], snrDb: 20, seed: 171, referencePower: rttyPower))
        let expected = [1_500.0, hz].sorted()
        expectTracks(tracker, at: expected, label)
        #expect(tracker.tracks.first { abs($0.frequencyHz - 1_500) < 3 }?.isFSKPair == true, "\(label): RTTY not paired")
        #expect(tracker.tracks.filter(\.isFSKPair).count == 1, "\(label)")
    }
    // RTTY at +10 dB with a −10 dB PSK31 120-170 Hz beyond the mark.
    for hz in [1_705.0, 1_735, 1_755] {
        let neighbour = bpsk31(hz, seconds: 5, amplitude: weak * 1.414, seed: 10)
        let tracker = SignalTracker()
        feed(tracker, scene([rtty, neighbour], snrDb: 10, seed: 172, referencePower: rttyPower))
        expectTracks(tracker, at: [1_500, hz], "+10 dB RTTY, −10 dB PSK31 at \(hz)")
    }
}

@Test(arguments: [40.0, 50.0])
func closePSKPairsStaySeparate(_ spacing: Double) {
    for p in [1.0, 0.5] {
        let a = bpsk31(1_500, seconds: 5, seed: 21, reversalProbability: p)
        let b = bpsk31(1_500 + spacing, seconds: 5, seed: 22, reversalProbability: p, timingOffset: 0.3, phase: 2)
        let tracker = SignalTracker()
        feed(tracker, scene([a, b], snrDb: 10, seed: 181))
        expectTracks(tracker, at: [1_500, 1_500 + spacing], "spacing \(spacing) p=\(p)")
    }
}

/// Ruling R8: the cursor can snap to a signal younger than the 6-frame confirmation.
@Test func strongestPeakFindsYoungSignals() {
    let tracker = SignalTracker()
    #expect(tracker.strongestPeak(near: 1_000, within: 50) == nil)
    let audio = scene([ModemTestSignals.tone(1_000, seconds: 2, amplitude: 0.5),
                       ModemTestSignals.tone(1_030, seconds: 2, amplitude: 0.05),
                       bpsk31(2_000, seconds: 2, seed: 1, reversalProbability: 1)],
                      snrDb: 10, seed: 191)
    // 4 warm-up frames plus one: peaks exist, but no track is confirmed yet.
    feed(tracker, audio[0..<(4_096 + 4 * 2_048)])
    #expect(tracker.tracks.isEmpty)
    let carrier = tracker.strongestPeak(near: 1_020, within: 40)
    #expect(carrier.map { abs($0 - 1_000) < 1 } == true, "carrier snap \(String(describing: carrier))")
    #expect(tracker.strongestPeak(near: 1_030, within: 5).map { abs($0 - 1_030) < 1 } == true)
    // An idle PSK31 snaps to its centre, not to a sideband line.
    let psk = tracker.strongestPeak(near: 2_010, within: 30)
    #expect(psk.map { abs($0 - 2_000) < 3 } == true, "PSK snap \(String(describing: psk))")
    #expect(tracker.strongestPeak(near: 1_500, within: 100) == nil)
    tracker.reset()
    #expect(tracker.strongestPeak(near: 1_000, within: 50) == nil)
}
