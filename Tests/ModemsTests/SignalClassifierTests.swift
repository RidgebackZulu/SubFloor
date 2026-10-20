import Testing
import Foundation
import DSPCore
@testable import Modems

// All audio is 12 kHz box audio. SNRs follow ruling R7 (signal power is the in-burst power, noise is
// measured in 2.5 kHz). Every classified Track comes from running a SignalTracker over the same audio,
// as the engine will, except where a test needs a track the tracker cannot produce (noise only).
//
// Thresholds were tuned on streaming-mode trial seeds 1...60 and FT8/WSPR-like seeds 3001... and
// 5001... only; the assertions use held-out seeds (1001... and up, 6001..., 7001...).

private let fs = 12_000.0

// MARK: - Helpers

/// Small deterministic generator for trial parameters (SplitMix64).
private struct TrialRandom {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * Double(next() >> 11) / Double(1 << 53)
    }

    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

private let words = ["CQ", "DE", "W1AW", "G3PLX", "OH2XX", "K", "PSE", "QTH", "NAME", "RST", "599", "TU", "73",
                     "TEST", "UR", "ES", "HR", "WX", "RIG", "ANT", "FB", "OM", "BK", "QRZ", "AGN", "GM", "GE"]

private func randomText(_ rng: inout TrialRandom, characters: Int) -> String {
    var s = ""
    while s.count < characters { s += (s.isEmpty ? "" : " ") + words[rng.int(words.count)] }
    return s
}

/// Keyed CW: `leadIn` s of silence, then the text, with 4 ms linear key ramps. Key-down power is
/// `amplitude²/2` (R7).
private func cwAudio(_ text: String, wpm: Double, hz: Double, amplitude: Float = 0.5, leadIn: Double) -> [Float] {
    let unit = Int(MorseCode.dotSeconds(wpm: wpm) * fs)
    var keyed = [Bool](repeating: false, count: Int(leadIn * fs))
    for e in MorseCode.timeline(for: text) { keyed += Array(repeating: e.on, count: e.units * unit) }
    keyed += [Bool](repeating: false, count: Int(0.5 * fs))
    let ramp = Float(0.004 * fs)
    var level: Float = 0
    return keyed.enumerated().map { i, on in
        level = on ? min(1, level + 1 / ramp) : max(0, level - 1 / ramp)
        return amplitude * level * Float(sin(2 * Double.pi * hz * Double(i) / fs))
    }
}

/// Phase-continuous M-FSK with `symbolSeconds` symbols: tone k at `baseHz + k·spacingHz`, starting
/// at `startSeconds` in a buffer of `totalSeconds`. Constant envelope, power amplitude²/2.
private func mfsk(_ symbols: [Int], baseHz: Double, spacingHz: Double, symbolSeconds: Double, startSeconds: Double,
                  totalSeconds: Double, amplitude: Float = 0.5) -> [Float] {
    var out = [Float](repeating: 0, count: Int(totalSeconds * fs))
    let start = Int(startSeconds * fs)
    let perSymbol = symbolSeconds * fs
    var phase = 0.0
    for n in start..<out.count {
        let k = Int(Double(n - start) / perSymbol)
        guard k < symbols.count else { break }
        phase += 2 * Double.pi * (baseHz + Double(symbols[k]) * spacingHz) / fs
        if phase > 2 * .pi { phase -= 2 * .pi }
        out[n] = amplitude * Float(sin(phase))
    }
    return out
}

/// FT8-like: 79 symbols of 8-FSK at 6.25 Hz spacing, 0.16 s each, Costas syncs at 0, 36 and 72,
/// random data between. Tone 0 is at `baseHz`. (Real FT8 is GFSK; Task 10's encoder provides it.)
private func ft8Like(baseHz: Double, startSeconds: Double, totalSeconds: Double, seed: UInt64) -> [Float] {
    var rng = TrialRandom(seed)
    let costas = [3, 1, 4, 0, 6, 5, 2]
    var symbols: [Int] = []
    for k in 0..<79 {
        if k < 7 { symbols.append(costas[k]) } else if (36..<43).contains(k) { symbols.append(costas[k - 36]) }
        else if k >= 72 { symbols.append(costas[k - 72]) } else { symbols.append(rng.int(8)) }
    }
    return mfsk(symbols, baseHz: baseHz, spacingHz: 6.25, symbolSeconds: 0.16, startSeconds: startSeconds,
                totalSeconds: totalSeconds)
}

/// WSPR-like: 4-FSK at 12000/8192 Hz spacing, 8192-sample symbols, random symbols, centred on `centreHz`.
/// (Task 11 provides the real encoder.)
private func wsprLike(centreHz: Double, seconds: Double, seed: UInt64) -> [Float] {
    var rng = TrialRandom(seed)
    let spacing = 12_000.0 / 8_192
    let symbols = (0..<162).map { _ in rng.int(4) }
    return mfsk(symbols, baseHz: centreHz - 1.5 * spacing, spacingHz: spacing, symbolSeconds: 8_192 / fs,
                startSeconds: 0.5, totalSeconds: seconds)
}

private func meanSquare(_ x: ArraySlice<Float>) -> Double {
    x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))
}

/// Element-wise sum, padded to the longest.
private func mix(_ parts: [Float]...) -> [Float] {
    var out = [Float](repeating: 0, count: parts.map(\.count).max() ?? 0)
    for p in parts { for i in p.indices { out[i] += p[i] } }
    return out
}

/// Runs a fresh tracker over `audio` in 1000-sample blocks, as the engine would feed it.
private func tracked(_ audio: ArraySlice<Float>) -> [Track] {
    let tracker = SignalTracker()
    var start = audio.startIndex
    while start < audio.endIndex {
        let end = min(start + 1_000, audio.endIndex)
        audio[start..<end].withUnsafeBufferPointer { tracker.process($0) }
        start = end
    }
    return tracker.tracks
}

/// The tracked signal nearest `hz` within ±`within` Hz.
private func track(near hz: Double, in tracks: [Track], within: Double = 10) -> Track? {
    tracks.filter { abs($0.frequencyHz - hz) <= within }.min { abs($0.frequencyHz - hz) < abs($1.frequencyHz - hz) }
}

/// Results of parallel jobs, filled under a lock.
private final class ResultBox<T>: @unchecked Sendable {
    var items: [T?]
    let lock = NSLock()
    init(_ n: Int) { items = Array(repeating: nil, count: n) }
}

/// Runs `count` independent jobs on all cores and returns their results in order.
private func parallel<T>(_ count: Int, _ job: @Sendable (Int) -> T) -> [T] {
    let box = ResultBox<T>(count)
    DispatchQueue.concurrentPerform(iterations: count) { i in
        let r = job(i)
        box.lock.lock(); box.items[i] = r; box.lock.unlock()
    }
    return box.items.map { $0! }
}

// MARK: - Streaming-mode trials

private enum Sent: String, CaseIterable, Sendable {
    case cw = "CW", bpsk = "BPSK31", qpsk = "QPSK31", rtty = "RTTY"

    func isCorrect(_ c: Classification?) -> Bool {
        guard let c else { return false }
        switch self {
        case .cw: return c.mode == .cw
        case .bpsk: return c.mode == .psk31 && c.submode == "BPSK31"
        case .qpsk: return c.mode == .psk31 && c.submode == "QPSK31"
        case .rtty: return c.mode == .rtty
        }
    }
}

private struct TrialResult: Sendable {
    var sent: Sent
    var seed: UInt64
    var hz: Double
    /// Nil when the tracker produced no track near the signal.
    var classification: Classification?
    var detail: String
}

/// One trial: a random signal of `sent`'s mode at a random 600-2800 Hz audio frequency in noise at
/// `snrDb` (CW at 15-35 WPM unless `wpm` is given). The tracker runs from the start of the audio to
/// a random point `elapsed` s into the transmission; the classifier gets that track and the last
/// `captureSeconds` of the audio.
private func trial(_ sent: Sent, seed: UInt64, snrDb: Double = 5, captureSeconds: Double = 2, wpm fixedWPM: Double? = nil,
                   elapsed: ClosedRange<Double> = 3.2...6.0) -> TrialResult {
    let modeSalt: UInt64 = switch sent { case .cw: 0; case .bpsk: 1; case .qpsk: 2; case .rtty: 3 }
    var rng = TrialRandom(seed &* 4 &+ modeSalt)
    let hz = rng.uniform(600...2_800)
    let leadIn = rng.uniform(0.5...1.5)
    let text = randomText(&rng, characters: 90)
    let clean: [Float]
    let power: Double
    var detail = ""
    switch sent {
    case .cw:
        let random = rng.uniform(15...35)
        let wpm = fixedWPM ?? random
        clean = cwAudio(text, wpm: wpm, hz: hz, leadIn: leadIn)
        power = 0.5 * 0.5 / 2
        detail = String(format: "%.0f WPM", wpm)
    case .bpsk, .qpsk:
        clean = PSK31Encoder.audio(text: text.lowercased(), frequencyHz: hz, qpsk: sent == .qpsk, leadInSeconds: leadIn)
        // PSK31's reference is its mean burst power (R12).
        power = meanSquare(clean[Int(leadIn * fs)...])
    case .rtty:
        clean = RTTYEncoder.audio(text: text, centerHz: hz, leadInSeconds: leadIn)
        power = 0.5 * 0.5 / 2
    }
    let audio = ModemTestSignals.awgn(clean, snrDb: snrDb, seed: seed &+ 10_000 &* (modeSalt + 1), signalPower: power)
    let end = min(audio.count, Int((leadIn + rng.uniform(elapsed)) * fs))
    let start = max(0, end - Int(captureSeconds * fs))
    let utc = rng.uniform(0..<60)
    guard let t = track(near: hz, in: tracked(audio[0..<end])) else {
        return TrialResult(sent: sent, seed: seed, hz: hz, classification: nil, detail: detail)
    }
    let c = SignalClassifier.classify(track: t, audio: audio[start..<end], sampleRate: fs, utcSecondOfMinute: utc)
    return TrialResult(sent: sent, seed: seed, hz: hz, classification: c, detail: detail)
}

private extension TrialRandom {
    mutating func uniform(_ range: Range<Double>) -> Double { uniform(range.lowerBound...range.upperBound) }
}

private let heldOutSeeds = Array(UInt64(1001)...1020)

/// The held-out trials at +5 dB, run once and shared by the tests that read them.
private let heldOutTrials: [TrialResult] = {
    let jobs = Sent.allCases.flatMap { s in heldOutSeeds.map { (s, $0) } }
    return parallel(jobs.count) { i in trial(jobs[i].0, seed: jobs[i].1) }
}()

private func label(_ c: Classification?) -> String {
    guard let c else { return "no track" }
    guard let mode = c.mode else { return "none" }
    return mode == .psk31 ? c.submode : mode.label
}

private func confusionMatrix(_ trials: [TrialResult]) -> String {
    let columns = ["CW", "BPSK31", "QPSK31", "RTTY", "FT8", "WSPR", "none", "no track"]
    var lines = ["sent \\ got " + columns.map { $0.padding(toLength: 9, withPad: " ", startingAt: 0) }.joined()]
    for s in Sent.allCases where trials.contains(where: { $0.sent == s }) {
        let row = trials.filter { $0.sent == s }
        let counts = columns.map { col in row.filter { label($0.classification) == col }.count }
        lines.append(s.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)
                     + counts.map { String($0).padding(toLength: 9, withPad: " ", startingAt: 0) }.joined())
    }
    return lines.joined(separator: "\n")
}

// MARK: - Plan tests

@Suite struct SignalClassifierTests {
    /// Plan: each of CW, BPSK31, QPSK31 and RTTY at +5 dB, random 600-2800 Hz, classified correctly
    /// in ≥ 90% of 20 trials, from the tracker's own track and the last 2 s of audio.
    @Test func classifiesEachMode() {
        let trials = heldOutTrials
        print("Classifier confusion matrix, +5 dB, 20 held-out trials per mode, 2 s captures:\n"
              + confusionMatrix(trials))
        for s in Sent.allCases {
            let row = trials.filter { $0.sent == s }
            let correct = row.filter { s.isCorrect($0.classification) }.count
            let misses = row.filter { !s.isCorrect($0.classification) }.map {
                "seed \($0.seed) \(String(format: "%.0f", $0.hz)) Hz \($0.detail): \(label($0.classification))"
            }
            #expect(correct >= 18, "\(s.rawValue): \(correct)/20 correct; misses \(misses)")
        }
        // Confidence is in range and consistent with the mode.
        for t in trials {
            guard let c = t.classification else { continue }
            #expect((0...1).contains(c.confidence))
            #expect(c.mode == nil ? c.confidence == 0 && c.submode.isEmpty : c.confidence >= 0.5)
        }
    }

    /// Keyed CW and PSK31 must never be taken for each other at +5 dB (the matrix from
    /// `classifiesEachMode`, plus a second set of trials at 4 s captures).
    @Test func cwAndPSKNeverConfused() {
        let longer = parallel(30) { i in
            trial([Sent.cw, .bpsk, .qpsk][i % 3], seed: UInt64(1_101 + i / 3), captureSeconds: 4)
        }
        print("Confusion matrix, +5 dB, 4 s captures (10 per mode):\n" + confusionMatrix(longer))
        for t in heldOutTrials + longer {
            switch t.sent {
            case .cw:
                #expect(t.classification?.mode != .psk31, "CW seed \(t.seed) at \(t.hz) Hz \(t.detail) taken for PSK31")
            case .bpsk, .qpsk:
                #expect(t.classification?.mode != .cw, "\(t.sent.rawValue) seed \(t.seed) at \(t.hz) Hz taken for CW")
            case .rtty:
                break
            }
        }
        for s in [Sent.cw, .bpsk, .qpsk] {
            let correct = longer.filter { $0.sent == s && s.isCorrect($0.classification) }.count
            #expect(correct >= 9, "\(s.rawValue) with 4 s captures: \(correct)/10")
        }
    }

    // TODO(Task 10): enable `classifiesFT8` by replacing `nil` with
    // `{ FT8Encoder.audio(message: $0, audioHz: $1) }` on the next line; nothing else changes.
    private static let ft8Encoder: (@Sendable (String, Double) -> [Float]?)? = nil

    /// Plan: an FT8 signal at +5 dB aligned to a slot, ≥ 90% of 20 trials. Pending until Task 10
    /// provides `FT8Encoder` (15 s of audio, signal from 0.5 s, `audioHz` = tone 0).
    @Test func classifiesFT8() {
        withKnownIssue("FT8Encoder arrives in Task 10") {
            guard let encoder = Self.ft8Encoder else {
                Issue.record("no FT8 encoder yet")
                return
            }
            let messages = ["CQ W1AW FN31", "CQ OH2XX KP20", "G3PLX W1AW -12", "W1AW G3PLX R-08", "CQ DX K1ABC FN42"]
            let results = parallel(20) { i -> (Bool, String) in
                var rng = TrialRandom(UInt64(2_001 + i))
                let hz = rng.uniform(600...2_750)
                guard let clean = encoder(messages[i % messages.count], hz) else { return (false, "encoder nil") }
                let audio = ModemTestSignals.awgn(clean, snrDb: 5, seed: UInt64(2_001 + i), signalPower: 0.125)
                let end = Int(5 * fs)
                let tracks = tracked(audio[0..<end]).filter { $0.frequencyHz > hz - 10 && $0.frequencyHz < hz + 54 }
                guard let t = tracks.max(by: { $0.snrDb < $1.snrDb }) else { return (false, "no track") }
                let slot = Double(15 * rng.int(4))
                let c = SignalClassifier.classify(track: t, audio: audio[0..<end], sampleRate: fs, utcSecondOfMinute: slot)
                return (c.mode == .ft8, label(c))
            }
            #expect(results.filter(\.0).count >= 18, "\(results.map(\.1))")
        } when: {
            Self.ft8Encoder == nil
        }
    }

    /// Plan: a steady unmodulated carrier is no mode, at any frequency and SNR, short or long capture.
    @Test func unknownForPlainCarrier() {
        let cases: [(Double, Double)] = [(700, 5), (1_500, 5), (1_520, 20), (2_400, 5), (2_900, 30), (1_450, -3)]
        let results = parallel(cases.count) { i -> [String] in
            let (hz, snr) = cases[i]
            let audio = ModemTestSignals.awgn(ModemTestSignals.tone(hz, seconds: 12, amplitude: 0.5), snrDb: snr,
                                              seed: UInt64(300 + i))
            guard let t = track(near: hz, in: tracked(audio[...])) else { return ["\(hz) Hz: no track"] }
            var bad: [String] = []
            for capture in [2.0, 4, 10] {
                let c = SignalClassifier.classify(track: t, audio: audio[(audio.count - Int(capture * fs))...],
                                                  sampleRate: fs, utcSecondOfMinute: 0.5)
                if c != .unknown { bad.append("\(hz) Hz \(snr) dB \(capture) s: \(label(c)) \(c.confidence)") }
            }
            return bad
        }
        #expect(results.allSatisfy { $0.isEmpty }, "\(results.flatMap { $0 })")
    }

    // MARK: - Further tests

    /// No signal at all: noise under a hand-made track (the tracker makes none), including tracks that
    /// claim FSK pairing or PSK31 sidebands, all-zero audio and a capture shorter than 2 s.
    @Test func noiseOnlyIsUnknown() {
        let results = parallel(12) { i -> [String] in
            let audio = ModemTestSignals.noise(seconds: 10, seed: UInt64(400 + i))
            let hz = 500 + 200 * Double(i)
            var bad: [String] = []
            for (fsk, offsets) in [(false, [Double]()), (true, []), (false, [-15.6, 15.6])] {
                let t = Track(id: 1, frequencyHz: hz, snrDb: -10, bandwidthHz: 10, firstSeenSample: 0,
                              lastActiveSample: audio.count, isQuiet: false, isFSKPair: fsk, peakOffsetsHz: offsets)
                for capture in [2.0, 10] {
                    let c = SignalClassifier.classify(track: t, audio: audio[(audio.count - Int(capture * fs))...],
                                                      sampleRate: fs, utcSecondOfMinute: 0)
                    if c != .unknown { bad.append("\(hz) Hz fsk \(fsk) \(offsets) \(capture) s: \(label(c))") }
                }
            }
            return bad
        }
        #expect(results.allSatisfy { $0.isEmpty }, "\(results.flatMap { $0 })")

        let t = Track(id: 1, frequencyHz: 1_500, snrDb: 10, bandwidthHz: 10, firstSeenSample: 0, lastActiveSample: 0,
                      isQuiet: false, isFSKPair: false, peakOffsetsHz: [])
        let zeros = [Float](repeating: 0, count: Int(4 * fs))
        #expect(SignalClassifier.classify(track: t, audio: zeros[...], sampleRate: fs, utcSecondOfMinute: nil) == .unknown)
        // Too short: even a clean signal is not judged on less than 2 s.
        let psk = PSK31Encoder.audio(text: "the quick brown fox jumps over the lazy dog", frequencyHz: 1_500, leadInSeconds: 0)
        #expect(SignalClassifier.classify(track: t, audio: psk[Int(1.2 * fs)..<Int(2.7 * fs)], sampleRate: fs,
                                          utcSecondOfMinute: nil) == .unknown)
        #expect(Classification.unknown == Classification(mode: nil, submode: "", confidence: 0))
    }

    /// Rule 5: a WSPR-like 4-FSK signal (1.4648 Hz spacing) in 1400-1600 Hz with 8 s of audio is WSPR;
    /// the same signal outside the sub-band, or a 2 s capture that cannot show its tones, is not.
    @Test func classifiesWSPRLikeSignal() {
        let results = parallel(20) { i -> (String, String) in
            var rng = TrialRandom(UInt64(7_001 + i))
            let inBand = i < 14
            let hz = inBand ? rng.uniform(1_420...1_580) : rng.uniform(1_800...2_600)
            let audio = ModemTestSignals.awgn(wsprLike(centreHz: hz, seconds: 12, seed: UInt64(7_001 + i)), snrDb: 5,
                                              seed: UInt64(7_101 + i), signalPower: 0.125)
            guard let t = track(near: hz, in: tracked(audio[...])) else { return ("no track", "no track") }
            let long = SignalClassifier.classify(track: t, audio: audio[(audio.count - Int(8 * fs))...], sampleRate: fs,
                                                 utcSecondOfMinute: 0)
            let short = SignalClassifier.classify(track: t, audio: audio[(audio.count - Int(2 * fs))...], sampleRate: fs,
                                                  utcSecondOfMinute: 0)
            return (label(long), label(short))
        }
        let inBand = results.prefix(14), outOfBand = results.dropFirst(14)
        #expect(inBand.filter { $0.0 == "WSPR" }.count >= 13, "in band, 8 s: \(inBand.map(\.0))")
        #expect(outOfBand.allSatisfy { $0.0 == "none" }, "out of band: \(outOfBand.map(\.0))")
        // A 2 s capture holds about three symbols: never another mode, and WSPR only if the tones showed.
        #expect(results.allSatisfy { ["WSPR", "none"].contains($0.1) }, "2 s captures: \(results.map(\.1))")
    }

    /// Rule 4 on an FT8-like 8-FSK signal (plain CPFSK; the real GFSK encoder is Task 10's): slot
    /// aligned it is FT8; the same signal starting 7 s into a slot is not; without UTC time it is
    /// FT8 with lower confidence.
    @Test func ft8LikeSignalNeedsSlotTiming() {
        let results = parallel(20) { i -> (aligned: Classification?, late: Classification?, noClock: Classification?) in
            var rng = TrialRandom(UInt64(6_001 + i))
            let hz = rng.uniform(600...2_750)
            let slot = Double(15 * rng.int(4))
            // Sample 0 is a slot boundary; the classifier gets 5 s ending at `end` with its UTC time.
            func run(start: Double, end: Double, utc: Double?) -> Classification? {
                let audio = ModemTestSignals.awgn(ft8Like(baseHz: hz, startSeconds: start, totalSeconds: end,
                                                          seed: UInt64(6_001 + i)),
                                                  snrDb: 5, seed: UInt64(6_101 + i), signalPower: 0.125)
                let tracks = tracked(audio[...]).filter { $0.frequencyHz > hz - 10 && $0.frequencyHz < hz + 54 }
                guard let t = tracks.max(by: { $0.snrDb < $1.snrDb }) else { return nil }
                let capture = audio[(audio.count - Int(5 * fs))...]
                return SignalClassifier.classify(track: t, audio: capture, sampleRate: fs,
                                                 utcSecondOfMinute: utc.map { $0 + end - 5 })
            }
            let dt = rng.uniform(-0.4...1.0)
            return (run(start: 0.5 + dt, end: 5, utc: slot), run(start: 7.5, end: 12, utc: slot),
                    run(start: 0.5 + dt, end: 5, utc: nil))
        }
        let aligned = results.filter { $0.aligned?.mode == .ft8 }.count
        #expect(aligned >= 18, "aligned: \(results.map { label($0.aligned) })")
        #expect(results.allSatisfy { $0.late?.mode != .ft8 }, "late: \(results.map { label($0.late) })")
        let noClock = results.compactMap(\.noClock).filter { $0.mode == .ft8 }
        #expect(noClock.count >= 18, "without UTC: \(results.map { label($0.noClock) })")
        #expect(noClock.allSatisfy { $0.confidence <= 0.75 })
        let alignedConfidence = results.compactMap(\.aligned).filter { $0.mode == .ft8 }.map(\.confidence)
        let meanAligned = alignedConfidence.reduce(0, +) / Float(max(alignedConfidence.count, 1))
        let noClockConfidence = noClock.map(\.confidence)
        let meanNoClock = noClockConfidence.reduce(0, +) / Float(max(noClockConfidence.count, 1))
        #expect(meanAligned > meanNoClock, "aligned \(meanAligned), without UTC \(meanNoClock)")

        // The same 8-FSK sent without a break for 17 s cannot be FT8 (a transmission lasts 12.64 s).
        let continuous = parallel(3) { i -> Classification? in
            var rng = TrialRandom(UInt64(6_201 + i))
            let hz = rng.uniform(600...2_750)
            let symbols = (0..<110).map { _ in rng.int(8) }
            let clean = mfsk(symbols, baseHz: hz, spacingHz: 6.25, symbolSeconds: 0.16, startSeconds: 0, totalSeconds: 17.5)
            let audio = ModemTestSignals.awgn(clean, snrDb: 5, seed: UInt64(6_301 + i), signalPower: 0.125)
            let tracks = tracked(audio[...]).filter { $0.frequencyHz > hz - 10 && $0.frequencyHz < hz + 54 }
            guard let t = tracks.max(by: { $0.snrDb < $1.snrDb }) else { return nil }
            return SignalClassifier.classify(track: t, audio: audio[(audio.count - Int(16 * fs))...], sampleRate: fs,
                                             utcSecondOfMinute: 1.5)
        }
        #expect(continuous.allSatisfy { $0 != nil && $0?.mode != .ft8 }, "continuous: \(continuous.map(label))")
    }

    /// Confidence is in [0, 1] and higher for clean signals (+20 dB) than marginal ones (−5 dB).
    @Test func confidenceFollowsSignalQuality() {
        let seeds = Array(UInt64(1_201)...1_210)
        let jobs = [Sent.cw, .bpsk, .qpsk, .rtty].flatMap { s in seeds.flatMap { [(s, $0, 20.0), (s, $0, -5.0)] } }
        let results = parallel(jobs.count) { i in (jobs[i].2, trial(jobs[i].0, seed: jobs[i].1, snrDb: jobs[i].2)) }
        for s in [Sent.cw, .bpsk, .qpsk, .rtty] {
            let clean = results.filter { $0.0 == 20 && $0.1.sent == s && s.isCorrect($0.1.classification) }
                .map { $0.1.classification!.confidence }
            let marginal = results.filter { $0.0 == -5 && $0.1.sent == s && s.isCorrect($0.1.classification) }
                .map { $0.1.classification!.confidence }
            let mean = { (x: [Float]) in x.reduce(0, +) / Float(max(x.count, 1)) }
            print("\(s.rawValue): clean \(clean.count)/10 mean confidence \(mean(clean)), marginal \(marginal.count)/10 mean \(mean(marginal))")
            #expect(clean.count == 10, "\(s.rawValue) at +20 dB: \(clean.count)/10")
            #expect(marginal.count >= 3, "\(s.rawValue) at −5 dB: \(marginal.count)/10 classified")
            #expect(mean(clean) > mean(marginal), "\(s.rawValue): clean \(mean(clean)), marginal \(mean(marginal))")
            #expect(clean.allSatisfy { (0.5...1).contains($0) } && marginal.allSatisfy { (0.5...1).contains($0) })
        }
    }

    /// The engine may hand over more than 2 s: longer captures classify just as well.
    @Test func longerCapturesClassifyToo() {
        let jobs = Sent.allCases.flatMap { s in (0..<5).map { (s, UInt64(1_301 + $0)) } }
        let results = parallel(jobs.count) { i in trial(jobs[i].0, seed: jobs[i].1, captureSeconds: 16) }
        for r in results {
            #expect(r.sent.isCorrect(r.classification), "\(r.sent.rawValue) seed \(r.seed): \(label(r.classification))")
        }
    }

    /// A neighbour 100-150 Hz away inside the classifier's ±150 Hz baseband doesn't change either
    /// signal's class: PSK31 beside CW, and CW beside RTTY.
    @Test func neighboursDoNotChangeTheClass() {
        let results = parallel(6) { i -> [String] in
            var rng = TrialRandom(UInt64(1_401 + i))
            let base = rng.uniform(800...2_000)
            let text = randomText(&rng, characters: 90)
            var bad: [String] = []
            if i < 3 {
                let psk = PSK31Encoder.audio(text: text.lowercased(), frequencyHz: base, qpsk: i == 1, leadInSeconds: 1)
                let cw = cwAudio(text, wpm: 22, hz: base + 120, leadIn: 1)
                let audio = ModemTestSignals.awgn(mix(psk, cw), snrDb: 5, seed: UInt64(1_451 + i),
                                                  signalPower: meanSquare(psk[Int(fs)...]))
                let end = Int(6 * fs)
                let tracks = tracked(audio[0..<end])
                let p = track(near: base, in: tracks).map {
                    SignalClassifier.classify(track: $0, audio: audio[(end - Int(2 * fs))..<end], sampleRate: fs,
                                              utcSecondOfMinute: nil)
                }
                let c = track(near: base + 120, in: tracks).map {
                    SignalClassifier.classify(track: $0, audio: audio[(end - Int(2 * fs))..<end], sampleRate: fs,
                                              utcSecondOfMinute: nil)
                }
                if p?.mode != .psk31 || p?.submode != (i == 1 ? "QPSK31" : "BPSK31") { bad.append("PSK beside CW: \(label(p))") }
                if c?.mode != .cw { bad.append("CW beside PSK: \(label(c))") }
            } else {
                let rtty = RTTYEncoder.audio(text: text, centerHz: base, leadInSeconds: 1)
                let cw = cwAudio(text, wpm: 25, hz: base + 235, leadIn: 1)
                let audio = ModemTestSignals.awgn(mix(rtty, cw), snrDb: 5, seed: UInt64(1_451 + i), signalPower: 0.125)
                let end = Int(6 * fs)
                let tracks = tracked(audio[0..<end])
                let r = track(near: base, in: tracks).map {
                    SignalClassifier.classify(track: $0, audio: audio[(end - Int(2 * fs))..<end], sampleRate: fs,
                                              utcSecondOfMinute: nil)
                }
                let c = track(near: base + 235, in: tracks).map {
                    SignalClassifier.classify(track: $0, audio: audio[(end - Int(2 * fs))..<end], sampleRate: fs,
                                              utcSecondOfMinute: nil)
                }
                if r?.mode != .rtty { bad.append("RTTY beside CW: \(label(r))") }
                if c?.mode != .cw { bad.append("CW beside RTTY: \(label(c))") }
            }
            return bad
        }
        #expect(results.allSatisfy { $0.isEmpty }, "\(results.flatMap { $0 })")
    }

    /// CW from 12 to 50 WPM at +5 dB with 2 s captures (the main trials cover 15-35 WPM).
    @Test(arguments: [12.0, 40, 50])
    func cwAcrossSpeeds(_ wpm: Double) {
        let results = parallel(10) { i in trial(.cw, seed: UInt64(1_601 + i), wpm: wpm) }
        let correct = results.filter { Sent.cw.isCorrect($0.classification) }.count
        #expect(correct >= 9, "\(wpm) WPM: \(results.map { label($0.classification) })")
    }

    /// The engine's first look: 2 s after the track is confirmed, a capture that still holds up to
    /// 1 s of noise before the transmission began.
    @Test func captureStartingBeforeTheOnset() {
        let jobs = [Sent.cw, .bpsk, .rtty].flatMap { s in (0..<8).map { (s, UInt64(1_701 + $0)) } }
        let results = parallel(jobs.count) { i in
            trial(jobs[i].0, seed: jobs[i].1, captureSeconds: 3, elapsed: 2.0...2.6)
        }
        for s in [Sent.cw, .bpsk, .rtty] {
            let correct = results.filter { $0.sent == s && s.isCorrect($0.classification) }.count
            #expect(correct >= 7, "\(s.rawValue): \(results.filter { $0.sent == s }.map { label($0.classification) })")
        }
    }

    /// BPSK31 idle (two equal lines at ±15.625 Hz: a reversal every symbol) is BPSK31, with the
    /// tracker's sidebands.
    @Test func idleBPSKIsBPSK() {
        let results = parallel(6) { i -> String in
            let hz = 700 + 350 * Double(i)
            let clean = mix(ModemTestSignals.tone(hz - 15.625, seconds: 4, amplitude: 0.25),
                            ModemTestSignals.tone(hz + 15.625, seconds: 4, amplitude: 0.25))
            let audio = ModemTestSignals.awgn(clean, snrDb: 5, seed: UInt64(1_801 + i), signalPower: 0.0625)
            guard let t = track(near: hz, in: tracked(audio[...])) else { return "no track" }
            let c = SignalClassifier.classify(track: t, audio: audio[(audio.count - Int(2 * fs))...], sampleRate: fs,
                                              utcSecondOfMinute: nil)
            return label(c)
        }
        #expect(results.allSatisfy { $0 == "BPSK31" }, "\(results)")
    }

    /// Stateless: the same input gives the same answer, whatever came before.
    @Test func deterministic() {
        let a = trial(.qpsk, seed: 1_501), b = trial(.qpsk, seed: 1_501)
        #expect(a.classification == b.classification)
        #expect(Sent.qpsk.isCorrect(a.classification))
    }

    /// Cost per call, for the engine's budget (up to 40 tracks, each classified after 2 s and every
    /// 10 s). Reported, with a loose bound that only catches a pathological regression.
    @Test func classifierCost() {
        let text = "the quick brown fox jumps over the lazy dog 0123456789 cq cq de w1aw pse k"
        let clean = PSK31Encoder.audio(text: text + " " + text, frequencyHz: 1_500, leadInSeconds: 1)
        let audio = ModemTestSignals.awgn(clean, snrDb: 5, seed: 7, signalPower: meanSquare(clean[Int(fs)...]))
        guard let t = track(near: 1_500, in: tracked(audio[0..<Int(17 * fs)])) else {
            Issue.record("no track"); return
        }
        for seconds in [2.0, 16.0] {
            let capture = audio[(Int(17 * fs) - Int(seconds * fs))..<Int(17 * fs)]
            var result = Classification.unknown
            let runs = 20
            let start = Date()
            for _ in 0..<runs { result = SignalClassifier.classify(track: t, audio: capture, sampleRate: fs, utcSecondOfMinute: 3) }
            let perCall = Date().timeIntervalSince(start) / Double(runs)
            print(String(format: "classify, %.0f s capture: %.2f ms per call (%@)", seconds, perCall * 1_000, label(result)))
            #expect(result.mode == .psk31)
            #expect(perCall < 0.25)
        }
    }
}
