import Testing
import Foundation
import DSPCore
@testable import Modems

// All audio is 12 kHz box audio. SNRs follow ruling R7: the noise is set once for the whole mixture
// from one reference signal's in-burst power, and every other signal's level is set relative to it.

private let fs = 12_000.0

// MARK: - Signals

/// Mean square of `x` after `leadIn` seconds: a PSK31 signal's in-burst power (rulings R7, R12).
private func burstPower(_ x: [Float], leadIn: Double) -> Double {
    let tail = x[Int(leadIn * fs)...]
    return tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(tail.count, 1))
}

private func psk(_ text: String, _ hz: Double, amplitude: Float = 0.5, leadIn: Double = 1) -> [Float] {
    PSK31Encoder.audio(text: text, frequencyHz: hz, leadInSeconds: leadIn, amplitude: amplitude)
}

/// PSK31 burst power at amplitude 0.5 (the reference most tests set the noise from).
private let pskPower = burstPower(psk("the quick brown fox jumps over the lazy dog", 1_500), leadIn: 1)

/// The PSK31 amplitude that puts a signal `db` above (or below) one of amplitude 0.5.
private func pskAmplitude(_ db: Double) -> Float { Float(0.5 * pow(10, db / 20)) }

/// The CW (or carrier) amplitude whose key-down power `amplitude²/2` is `db` above the PSK31 reference.
private func toneAmplitude(_ db: Double) -> Float { Float((2 * pskPower * pow(10, db / 10)).squareRoot()) }

/// Keyed CW with 4 ms ramps: `leadIn` s of silence, then the text, then 0.5 s of silence.
private func cw(_ text: String, wpm: Double = 20, _ hz: Double, amplitude: Float, leadIn: Double = 1) -> [Float] {
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

private func carrier(_ hz: Double, seconds: Double, amplitude: Float, start: Double = 0) -> [Float] {
    [Float](repeating: 0, count: Int(start * fs)) + ModemTestSignals.tone(hz, seconds: seconds, amplitude: amplitude)
}

/// Element-wise sum, padded (with silence) to `seconds` or the longest part.
private func mix(seconds: Double = 0, _ parts: [Float]...) -> [Float] {
    mix(seconds: seconds, parts)
}

private func mix(seconds: Double = 0, _ parts: [[Float]]) -> [Float] {
    var out = [Float](repeating: 0, count: max(Int(seconds * fs), parts.map(\.count).max() ?? 0))
    for p in parts { for i in p.indices where i < out.count { out[i] += p[i] } }
    return out
}

/// Adds noise for `snrDb` relative to the PSK31 reference power.
private func noisy(_ x: [Float], snrDb: Double, seed: UInt64) -> [Float] {
    ModemTestSignals.awgn(x, snrDb: snrDb, seed: seed, signalPower: pskPower)
}

// MARK: - Running the engine

/// Everything an engine run produced.
private struct Run {
    var text: [Int: String] = [:]
    var signals: [SignalSnapshot]?
    var listen: [Float] = []
    var cursor: CursorFrame?
    var cursorFrames = 0
    var signalUpdates = 0
    var outputs = 0

    func text(_ id: Int?) -> String { id.flatMap { text[$0] } ?? "" }
}

/// Feeds `audio[range]` in `chunk`-sample blocks; `each` sees every output after it is recorded.
private func feed(_ engine: ModemEngine, _ audio: [Float], _ range: Range<Int>? = nil, chunk: Int = 1_024,
                  into run: inout Run, each: ((ModemOutput, Int) -> Void)? = nil) {
    let r = range ?? 0..<audio.count
    var start = r.lowerBound
    while start < r.upperBound {
        let end = min(start + chunk, r.upperBound)
        let out = audio[start..<end].withUnsafeBufferPointer { engine.process($0, sampleIndex: start) }
        for t in out.text { run.text[t.trackID, default: ""] += t.text }
        if let s = out.signals { run.signals = s; run.signalUpdates += 1 }
        if let c = out.cursor { run.cursor = c; run.cursorFrames += 1 }
        run.listen += out.listenAudio
        run.outputs += 1
        each?(out, end)
        start = end
    }
}

private func samples(_ seconds: Double) -> Int { Int(seconds * fs) }

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

/// CW text with runs of spaces collapsed (word gaps vary).
private func clean(_ s: String) -> String { s.split(separator: " ").joined(separator: " ") }

private func accuracy(_ sent: String, _ received: String) -> Double {
    ModemTestSignals.characterAccuracy(sent: sent, received: trimmed(received))
}

private func snapshot(near hz: Double, in signals: [SignalSnapshot]?, within: Double = 3) -> SignalSnapshot? {
    signals?.filter { abs($0.frequencyHz - hz) <= within }.min { abs($0.frequencyHz - hz) < abs($1.frequencyHz - hz) }
}

private func track(near hz: Double, _ engine: ModemEngine, within: Double = 3) -> Track? {
    engine.currentTracks.first { abs($0.frequencyHz - hz) <= within }
}

/// Power of the `hz` component of `x` (Goertzel, normalised so a sine of amplitude A reads A²/2).
private func tonePower(_ x: ArraySlice<Float>, _ hz: Double) -> Double {
    let w = 2 * Double.pi * hz / fs
    var re = 0.0, im = 0.0
    for (k, v) in x.enumerated() {
        re += Double(v) * cos(w * Double(k))
        im -= Double(v) * sin(w * Double(k))
    }
    let n = Double(x.count)
    return 2 * (re * re + im * im) / (n * n)
}

private func db(_ ratio: Double) -> Double { 10 * log10(ratio) }

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

private let pskTexts = [
    "cq cq cq de g3plx g3plx pse k the weather here is fine and the rig is a home made transceiver at fifty watts",
    "hello om thanks for the call ur rst is 599 599 name is john qth is london hw copy so far btu",
    "the quick brown fox jumps over the lazy dog while the five boxing wizards jump quickly 1234567890",
    "w1aw de oh2xx good morning dear friend the band is open to europe today and conditions are good",
    "testing the multi signal modem engine with several psk31 carriers spread across the whole box now",
]
/// FT8-like: 79 symbols of phase-continuous 8-FSK, 6.25 Hz spacing, 0.16 s each, with Costas syncs
/// at 0, 36 and 72 and seeded data between, starting `start` s into the buffer. Constant envelope at
/// amplitude 0.5. (Task 10's encoder provides real GFSK FT8.)
private func ft8Like(baseHz: Double, start: Double, seconds: Double, seed: UInt64) -> [Float] {
    let costas = [3, 1, 4, 0, 6, 5, 2]
    var state = seed
    var symbols: [Int] = []
    for k in 0..<79 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        if k < 7 { symbols.append(costas[k]) } else if (36..<43).contains(k) { symbols.append(costas[k - 36]) }
        else if k >= 72 { symbols.append(costas[k - 72]) } else { symbols.append(Int(state >> 61)) }
    }
    var out = [Float](repeating: 0, count: Int(seconds * fs))
    let first = Int(start * fs), perSymbol = 0.16 * fs
    var phase = 0.0
    for n in first..<out.count {
        let k = Int(Double(n - first) / perSymbol)
        guard k < symbols.count else { break }
        phase += 2 * Double.pi * (baseHz + 6.25 * Double(symbols[k])) / fs
        if phase > 2 * .pi { phase -= 2 * .pi }
        out[n] = 0.5 * Float(sin(phase))
    }
    return out
}

private let cwTexts = ["CQ CQ DE W1AW W1AW K TU 599 NAME JOHN QTH CT BK", "TEST DE OH2XX OH2XX PSE K 73 GL ES DX"]

// MARK: - Tests

@Suite struct ModemEngineTests {
    /// Five PSK31 signals at +5 dB and two CW signals at +10 dB, 40 s, auto-detect with PSK31 as the
    /// fallback. Also measures the engine's speed (printed, for the report).
    @Test func parallelDecode() {
        let pskHz = [600.0, 900, 1_300, 1_900, 2_600]
        let cwHz = [2_200.0, 3_000]
        var parts = zip(pskTexts, pskHz).map { psk($0, $1) }
        parts += zip(cwTexts, cwHz).map { cw($0, $1, amplitude: toneAmplitude(10)) }
        let audio = noisy(mix(seconds: 40, parts), snrDb: 5, seed: 901)
        let engine = ModemEngine()
        engine.settings = ModemSettings(mode: .psk31, autoDetect: true)
        var run = Run()
        let t0 = Date()
        feed(engine, audio, into: &run)
        let elapsed = Date().timeIntervalSince(t0)
        print("ModemEngine parallelDecode: \(String(format: "%.3f", elapsed)) s for 40 s of audio, "
              + "real-time factor \(String(format: "%.4f", elapsed / 40)) (\(String(format: "%.0f", 40 / elapsed))x real time), "
              + "\(engine.classificationsRun) classifications, \(engine.decodersCreated) decoders created")

        for (sent, hz) in zip(pskTexts, pskHz) {
            let s = snapshot(near: hz, in: run.signals)
            #expect(s?.mode == .psk31, "PSK31 at \(hz): \(String(describing: s))")
            let got = run.text(s?.id)
            #expect(accuracy(sent, got) >= 0.95, "PSK31 at \(hz): '\(got)'")
        }
        for (sent, hz) in zip(cwTexts, cwHz) {
            let s = snapshot(near: hz, in: run.signals)
            #expect(s?.mode == .cw, "CW at \(hz): \(String(describing: s))")
            let got = clean(run.text(s?.id))
            #expect(accuracy(sent, got) >= 0.95, "CW at \(hz): '\(got)'")
        }
        // Nothing decoded under any other key.
        let keys = Set(pskHz.compactMap { snapshot(near: $0, in: run.signals)?.id } + cwHz.compactMap { snapshot(near: $0, in: run.signals)?.id })
        for (key, text) in run.text where !keys.contains(key) {
            #expect(trimmed(text).isEmpty, "stray text under \(key): '\(text)'")
        }
    }

    @Test func manualModeDecodesAllWithOneModem() {
        let hz = [700.0, 1_400, 2_100]
        let texts = ["CQ CQ DE W1AW K", "TEST DE OH2XX K", "PARIS PARIS 73"]
        let audio = noisy(mix(zip(texts, hz).map { cw($0, $1, amplitude: toneAmplitude(10)) }), snrDb: 0, seed: 902)
        let engine = ModemEngine()
        engine.settings = ModemSettings(mode: .cw)
        var run = Run()
        feed(engine, audio + ModemTestSignals.noise(seconds: 1, sigma: 0, seed: 1), into: &run)
        for (sent, f) in zip(texts, hz) {
            let s = snapshot(near: f, in: run.signals)
            #expect(s?.mode == .cw)
            let got = clean(run.text(s?.id))
            #expect(accuracy(sent, got) >= 0.95, "CW at \(f): '\(got)'")
        }
    }

    /// 60 s of noise in each mode and with auto-detect, without and (stronger than the plan) with the
    /// cursor locked on empty noise, which runs a decoder for the whole minute.
    @Test func noGarbage() {
        let configs: [(ModemSettings, Bool)] = [ModemSettings(mode: .cw), ModemSettings(mode: .psk31),
                                                ModemSettings(mode: .rtty), ModemSettings(mode: .psk31, autoDetect: true),
                                                ModemSettings(mode: .rtty, autoDetect: true)]
            .flatMap { [($0, false), ($0, true)] }
        let counts = parallel(configs.count) { i in
            let (settings, withCursor) = configs[i]
            let audio = ModemTestSignals.noise(seconds: 60, sigma: 0.05, seed: UInt64(950 + i / 2))
            let engine = ModemEngine()
            engine.settings = settings
            if withCursor { engine.lockCursor(atAudioHz: 1_500) }
            var run = Run()
            feed(engine, audio, into: &run)
            return (run.text.values.joined().filter { !$0.isWhitespace }.count, engine.currentTracks.count)
        }
        for (i, c) in counts.enumerated() {
            #expect(c.0 == 0, "\(configs[i]): \(c.0) characters, \(c.1) tracks")
        }
    }

    @Test func cursorAlwaysDecodedBeyondCap() {
        let hz = [700.0, 1_200, 1_800, 2_400]
        let levels = [15.0, 12, 9, 0]
        let texts = Array(pskTexts.prefix(4))
        let parts = (0..<4).map { psk(texts[$0], hz[$0], amplitude: pskAmplitude(levels[$0])) }
        let audio = noisy(mix(seconds: 32, parts), snrDb: 3, seed: 903)
        let engine = ModemEngine(maxDecoders: 2)
        engine.settings = ModemSettings(mode: .psk31)
        var run = Run()
        var maxDecoders = 0
        feed(engine, audio, 0..<samples(5), into: &run) { _, _ in maxDecoders = max(maxDecoders, engine.decoderKeys.count) }
        let weakest = track(near: 2_400, engine)
        #expect(weakest != nil)
        #expect(!engine.decoderKeys.contains(weakest?.id ?? 0), "the weakest is not decoded before the lock")
        engine.lockCursor(atAudioHz: 2_403)
        #expect(engine.cursorTrackID == weakest?.id)
        feed(engine, audio, samples(5)..<audio.count, into: &run) { _, _ in maxDecoders = max(maxDecoders, engine.decoderKeys.count) }
        #expect(maxDecoders <= 2)
        #expect(engine.decoderKeys.contains(weakest?.id ?? 0))
        let got = run.text(weakest?.id)
        #expect(accuracy(texts[3], got) >= 0.95, "'\(got)'")
        // The strongest keeps the other decoder.
        #expect(accuracy(texts[0], run.text(track(near: 700, engine)?.id)) >= 0.95)
    }

    /// The plan's version (RTTY at −3 dB "below the classifier's threshold") does not hold: the
    /// classifier detects RTTY down to about −8 dB. The intent is kept: a cursor locked on a signal
    /// the classifier has not classified decodes in the fallback mode. Here the cursor is locked
    /// (provisionally, there is no signal yet) before a short RTTY transmission starts at −3 dB, and
    /// the test checks that the whole text was decoded while the classifier had not classified the
    /// signal (it only classifies a track seen for 2 s).
    @Test func unclassifiedCursorUsesFallbackMode() {
        let sent = "CQ W1AW K"
        let rtty = RTTYEncoder.audio(text: sent, centerHz: 1_500, leadInSeconds: 3)
        let audio = ModemTestSignals.awgn(mix(seconds: 12, rtty), snrDb: -3, seed: 904, signalPower: 0.5 * 0.5 / 2)
        let engine = ModemEngine()
        engine.settings = ModemSettings(mode: .rtty, autoDetect: true)
        var run = Run()
        feed(engine, audio, 0..<samples(1), into: &run)
        engine.lockCursor(atAudioHz: 1_500)
        let provisional = engine.cursorTrackID ?? 0
        #expect(provisional < 0, "no track yet: the cursor is provisional")
        feed(engine, audio, samples(1)..<samples(1) + 1_024, into: &run)
        #expect(engine.decoderMode(provisional) == .rtty, "the fallback mode decodes it")

        var lineage = Set([provisional])
        var textWhileUnclassified = ""
        var everClassified = false
        feed(engine, audio, (samples(1) + 1_024)..<audio.count, into: &run) { out, _ in
            if let key = engine.cursorTrackID { lineage.insert(key) }
            let classified = lineage.contains { $0 > 0 && engine.classification(ofTrack: $0)?.mode != nil }
            everClassified = everClassified || classified
            if !everClassified {
                for t in out.text where lineage.contains(t.trackID) { textWhileUnclassified += t.text }
            }
        }
        #expect(accuracy(sent, textWhileUnclassified) >= 0.95, "'\(textWhileUnclassified)'")
        // The cursor was adopted by the signal's track, and nothing was decoded twice.
        #expect((engine.cursorTrackID ?? 0) > 0)
        let all = lineage.sorted().map { run.text($0) }.joined()
        #expect(accuracy(sent, all) >= 0.95, "'\(all)'")
    }

    @Test func listenAudioNarrowVsWide() {
        let audio = mix(carrier(1_500, seconds: 8, amplitude: 0.3), carrier(2_500, seconds: 8, amplitude: 0.3))
        let input = ModemTestSignals.awgn(audio, snrDb: 30, seed: 905, signalPower: 0.045)

        // No cursor: the listen audio is the box audio.
        do {
            let engine = ModemEngine()
            engine.settings = ModemSettings(mode: .psk31)
            var run = Run()
            feed(engine, input, 0..<samples(3), into: &run)
            #expect(run.listen == Array(input[0..<samples(3)]))
        }

        let engine = ModemEngine()
        engine.settings = ModemSettings(mode: .psk31)
        var run = Run()
        feed(engine, input, 0..<samples(2), into: &run)
        engine.lockCursor(atAudioHz: 1_500)
        feed(engine, input, samples(2)..<samples(5), into: &run)
        let narrow = run.listen[samples(4)..<samples(5)]
        let reference = input[samples(4)..<samples(5)]
        let rejection = db(tonePower(reference, 2_500) / tonePower(narrow, 2_500))
        let passed = db(tonePower(narrow, 1_500) / tonePower(reference, 1_500))
        #expect(rejection >= 30, "2500 Hz only \(rejection) dB down")
        #expect(abs(passed) <= 1, "1500 Hz changed by \(passed) dB")

        engine.settings.audioWide = true
        feed(engine, input, samples(5)..<samples(8), into: &run)
        let wide = run.listen[samples(6)..<samples(8)]
        let wideRef = input[samples(6)..<samples(8)]
        let wideLoss = db(tonePower(wideRef, 2_500) / tonePower(wide, 2_500))
        #expect(abs(wideLoss) <= 3, "wide: 2500 Hz changed by \(wideLoss) dB")
    }

    @Test func boxMoveClears() {
        let old = noisy(psk("oldtext oldtext oldtext the box is about to move away from here", 1_200), snrDb: 10, seed: 906)
        let new = noisy(psk("newtext at another frequency entirely", 2_000), snrDb: 10, seed: 907)
        let engine = ModemEngine()
        engine.settings = ModemSettings(mode: .psk31)
        var before = Run()
        feed(engine, old, 0..<samples(12), into: &before)
        let oldIDs = Set(before.text.keys)
        #expect(before.text.values.joined().contains("oldtext"))
        engine.lockCursor(atAudioHz: 1_200)

        engine.resetForBoxMove()
        #expect(engine.cursorTrackID == nil)
        #expect(engine.decoderKeys.isEmpty)
        var after = Run()
        var first = true
        feed(engine, new, into: &after) { out, _ in
            if first { #expect(out.signals == []); first = false }
        }
        for key in after.text.keys { #expect(!oldIDs.contains(key) && key > (oldIDs.max() ?? 0)) }
        let newText = after.text.values.joined()
        #expect(!newText.contains("old") && !newText.contains("box"), "'\(newText)'")
        #expect(newText.contains("newtext"))
        #expect(after.signals?.allSatisfy { !oldIDs.contains($0.id) } == true)
    }

    /// The signal sends "eeee…": each character (Varicode 11, then 00) returns to the same phase, so a
    /// carrier line stays at the centre. (Ordinary text spreads its power over a ±20 Hz hump whose
    /// highest bin can be anywhere in it, and idle reversals null the centre, so neither can show
    /// that the micro spectrum is centred.)
    @Test func cursorFrameContents() {
        let audio = noisy(psk(String(repeating: "e", count: 150), 1_500), snrDb: 10, seed: 908)
        let engine = ModemEngine()
        engine.settings = ModemSettings(mode: .psk31)
        var run = Run()
        feed(engine, audio, 0..<samples(3), into: &run)
        #expect(run.cursorFrames == 0)
        engine.lockCursor(atAudioHz: 1_502)
        feed(engine, audio, samples(3)..<samples(10), into: &run)
        // At most one frame per 1/30 s of audio (1024-sample blocks: one per block).
        #expect(run.cursorFrames <= Int(7.0 * 30) + 1)
        guard let f = run.cursor else { Issue.record("no cursor frame"); return }
        #expect(f.iq.count >= 64)
        #expect(f.spectrumDb.count == 401)
        let peak = f.spectrumDb.indices.max { f.spectrumDb[$0] < f.spectrumDb[$1] }!
        #expect(abs(peak - 200) <= 1, "peak at bin \(peak), centre \(f.spectrumCenterHz)")
        #expect(f.waveform.count == 480)
        #expect(abs(f.waveform[0]) < 0.01 && f.waveform[1] > f.waveform[0], "\(f.waveform.prefix(3))")
        #expect(abs(f.frequencyHz - 1_500) < 0.5)
        #expect(f.submode == "BPSK31")
        #expect(f.symbolRate == 31.25)
        #expect(f.snrDb > 5 && f.snrDb < 15)
    }

    // MARK: Allocation

    /// Three equal signals, all transmitting throughout, compete for two decoders: SNR jitter must not
    /// swap them. A much stronger signal arriving later does take a decoder.
    @Test func decoderAllocationHasHysteresis() {
        func long(_ i: Int) -> String { pskTexts[i] + " " + pskTexts[(i + 1) % pskTexts.count] }
        let parts = [psk(long(0), 800), psk(long(1), 1_500), psk(long(2), 2_200),
                     psk(pskTexts[3], 2_700, amplitude: pskAmplitude(14), leadIn: 18)]
        let audio = noisy(mix(seconds: 30, parts), snrDb: 6, seed: 909)
        let engine = ModemEngine(maxDecoders: 2)
        engine.settings = ModemSettings(mode: .psk31)
        var run = Run()
        var held: [[Int]] = []
        feed(engine, audio, 0..<samples(17), into: &run) { _, _ in held.append(engine.decoderKeys) }
        #expect(engine.decodersCreated == 2, "created \(engine.decodersCreated)")
        let settled = held.last ?? []
        #expect(held.suffix(held.count / 2).allSatisfy { $0 == settled })
        feed(engine, audio, samples(17)..<samples(30), into: &run)
        let strong = track(near: 2_700, engine)
        #expect(engine.decoderKeys.contains(strong?.id ?? 0))
        #expect(engine.decodersCreated == 3, "created \(engine.decodersCreated)")
        #expect(engine.decoderKeys.count == 2)
    }

    /// A removed track's decoder goes; a cursor on a removed track carries on provisionally.
    @Test func trackRemovalDropsDecoder() {
        let a = carrier(1_000, seconds: 3, amplitude: toneAmplitude(15), start: 0.5)
        let b = carrier(2_000, seconds: 3, amplitude: toneAmplitude(15), start: 0.5)
        let audio = mix(a, b) + [Float](repeating: 0, count: samples(125))
        let input = noisy(audio, snrDb: 0, seed: 910)
        let engine = ModemEngine()
        engine.settings = ModemSettings(mode: .cw)
        var run = Run()
        feed(engine, input, 0..<samples(3), chunk: 4_096, into: &run)
        guard let ta = track(near: 1_000, engine), let tb = track(near: 2_000, engine) else {
            Issue.record("tracks not found"); return
        }
        engine.lockCursor(atAudioHz: 2_000)
        feed(engine, input, samples(3)..<samples(30), chunk: 4_096, into: &run)
        #expect(Set(engine.decoderKeys) == [ta.id, tb.id], "quiet tracks keep their decoders")
        #expect(run.signals?.first { $0.id == ta.id }?.isQuiet == true)
        feed(engine, input, samples(30)..<input.count, chunk: 4_096, into: &run)
        #expect(engine.currentTracks.isEmpty)
        let key = engine.cursorTrackID ?? 0
        #expect(key < 0, "the cursor carries on provisionally")
        #expect(engine.decoderKeys == [key])
    }

    // MARK: Cursor

    /// Nudging walks the tracks by frequency and stops at either end (no wrap-around).
    @Test func nudgeCursorOrderAndClamp() {
        let parts = [2_200.0, 800, 1_500].map { carrier($0, seconds: 4, amplitude: toneAmplitude(10)) }
        let audio = noisy(mix(parts), snrDb: 0, seed: 911)
        let engine = ModemEngine()
        engine.settings = ModemSettings(mode: .cw)
        var run = Run()
        feed(engine, audio, into: &run)
        guard let low = track(near: 800, engine)?.id, let mid = track(near: 1_500, engine)?.id,
              let high = track(near: 2_200, engine)?.id else { Issue.record("tracks not found"); return }

        engine.nudgeCursor(1)
        #expect(engine.cursorTrackID == low, "unlocked: up goes to the lowest")
        var visited: [Int?] = []
        for d in [1, 1, 1, -1, -1, -1] {
            engine.nudgeCursor(d)
            visited.append(engine.cursorTrackID)
        }
        #expect(visited == [mid, high, high, mid, low, low])
        engine.unlockCursor()
        engine.nudgeCursor(-1)
        #expect(engine.cursorTrackID == high, "unlocked: down goes to the highest")
        // From an untracked (provisional) cursor, to the nearest track on each side.
        engine.lockCursor(atAudioHz: 1_200)
        #expect((engine.cursorTrackID ?? 0) < 0)
        engine.nudgeCursor(-1)
        #expect(engine.cursorTrackID == low)
        engine.lockCursor(atAudioHz: 1_200)
        engine.nudgeCursor(1)
        #expect(engine.cursorTrackID == mid)
    }

    @Test func unlockCursorRestoresWideAudio() {
        let input = noisy(carrier(1_500, seconds: 6, amplitude: toneAmplitude(10)), snrDb: 0, seed: 912)
        let engine = ModemEngine()
        engine.settings = ModemSettings(mode: .cw)
        var run = Run()
        feed(engine, input, 0..<samples(2), into: &run)
        engine.lockCursor(atAudioHz: 1_500)
        let id = engine.cursorTrackID
        #expect((id ?? 0) > 0)
        feed(engine, input, samples(2)..<samples(3), into: &run)
        #expect(run.cursor != nil)
        #expect(run.signals?.first { $0.isCursor }?.id == id)
        #expect(run.listen[samples(2.5)..<samples(3)] != input[samples(2.5)..<samples(3)])

        engine.unlockCursor()
        #expect(engine.cursorTrackID == nil)
        var after = Run()
        feed(engine, input, samples(3)..<samples(6), into: &after)
        #expect(after.cursorFrames == 0)
        #expect(after.signals?.contains { $0.isCursor } == false)
        // After the 20 ms cross-fade the box audio passes untouched.
        #expect(Array(after.listen[samples(0.1)...]) == Array(input[samples(3.1)..<samples(6)]))

        // A provisional cursor's decoder goes with it.
        engine.lockCursor(atAudioHz: 3_000)
        let key = engine.cursorTrackID ?? 0
        feed(engine, input, samples(5)..<samples(6), into: &after)
        #expect(engine.decoderKeys.contains(key))
        engine.unlockCursor()
        feed(engine, input, samples(5)..<samples(5) + 2_048, into: &after)
        #expect(!engine.decoderKeys.contains(key))
    }

    // MARK: Consistency

    @Test func textIsIndependentOfChunkSize() {
        let parts = [psk(pskTexts[0], 900), psk(pskTexts[1], 1_700), cw(cwTexts[0], 2_500, amplitude: toneAmplitude(8))]
        let audio = noisy(mix(seconds: 20, parts), snrDb: 5, seed: 913)
        let chunks = [1_024, 333, 4_800, 12_000]
        let runs = parallel(chunks.count) { i in
            let engine = ModemEngine()
            engine.settings = ModemSettings(mode: .psk31, autoDetect: true)
            var run = Run()
            feed(engine, audio, chunk: chunks[i], into: &run)
            return (run.text, engine.currentTracks.map { "\($0.id)@\($0.frequencyHz)" })
        }
        #expect(!runs[0].0.isEmpty)
        for r in runs.dropFirst() {
            #expect(r.0 == runs[0].0)
            #expect(r.1 == runs[0].1)
        }
    }

    /// Changing the mode rebuilds the decoders in the new mode; the new decoder re-reads the history,
    /// so the text is complete. Switching back and forth never reports text twice.
    @Test func modeSwitchRebuildsDecoders() {
        let sent = pskTexts[2]
        let audio = noisy(psk(sent, 1_500), snrDb: 10, seed: 914)
        let engine = ModemEngine()
        engine.settings = ModemSettings(mode: .cw)
        var run = Run()
        feed(engine, audio, 0..<samples(6), into: &run)
        guard let id = track(near: 1_500, engine)?.id else { Issue.record("no track"); return }
        #expect(engine.decoderMode(id) == .cw)
        let created = engine.decodersCreated
        let cwText = run.text(id)

        engine.settings.mode = .psk31
        feed(engine, audio, samples(6)..<samples(7), into: &run)
        #expect(engine.decoderMode(id) == .psk31)
        #expect(engine.decodersCreated == created + 1)
        engine.settings.audioWide = true
        feed(engine, audio, samples(7)..<samples(8), into: &run)
        #expect(engine.decodersCreated == created + 1, "an audio change keeps the decoders")

        // Off and back: no decoders while off, and the new decoder resumes where the last one stopped.
        engine.settings.mode = nil
        feed(engine, audio, samples(8)..<samples(9), into: &run)
        #expect(engine.decoderKeys.isEmpty)
        engine.settings.mode = .psk31
        feed(engine, audio, samples(9)..<audio.count, into: &run)
        let pskText = String(run.text(id).dropFirst(cwText.count))
        // One second of the transmission (about 4 characters) was not decoded while off.
        #expect(accuracy(sent, pskText) >= 0.9, "'\(pskText)'")
        #expect(pskText.components(separatedBy: "brown").count == 2, "text reported twice: '\(pskText)'")
    }

    /// Review Focus 2: a signal drifting 1 Hz/s for 30 s (twice the PSK31 lock range) keeps its track
    /// id and stays decoded, through decoder hand-overs.
    @Test func driftingSignalStaysDecoded() {
        let sent = pskTexts[0] + " " + pskTexts[1]
        let clear = PSK31Encoder.audio(text: sent, leadInSeconds: 1, frequencyAt: { t in 1_200 + min(max(t - 3, 0), 30) })
        let audio = noisy(clear, snrDb: 5, seed: 915)
        let engine = ModemEngine()
        engine.settings = ModemSettings(mode: .psk31)
        var run = Run()
        feed(engine, audio, 0..<samples(3), into: &run)
        let id = track(near: 1_200, engine)?.id
        feed(engine, audio, samples(3)..<audio.count, into: &run)
        let end = engine.currentTracks.first { $0.id == id }
        #expect(end != nil && abs((end?.frequencyHz ?? 0) - 1_230) <= 2, "\(engine.currentTracks)")
        let got = run.text(id)
        #expect(accuracy(sent, got) >= 0.95, "'\(got)'")
        #expect(run.text.keys.allSatisfy { $0 == id })
    }

    /// QPSK31 idle reads as BPSK31 to the classifier; the snapshot shows the decoder's live submode.
    @Test func snapshotsReportDecoderSubmode() {
        let sent = pskTexts[1]
        let audio = noisy(PSK31Encoder.audio(text: sent, frequencyHz: 1_500, qpsk: true), snrDb: 10, seed: 917)
        let engine = ModemEngine()
        engine.settings = ModemSettings(mode: .psk31, autoDetect: true)
        var run = Run()
        feed(engine, audio, 0..<samples(12), into: &run)
        let s = snapshot(near: 1_500, in: run.signals)
        #expect(s?.mode == .psk31)
        #expect(s?.submode == "QPSK31", "\(String(describing: s)), classified \(String(describing: engine.classification(ofTrack: s?.id ?? 0)))")
        feed(engine, audio, samples(12)..<audio.count, into: &run)
        #expect(accuracy(sent, run.text(s?.id)) >= 0.95, "'\(run.text(s?.id))'")
    }

    /// The classifier gets the UTC time of its capture from the times passed to `process`: an
    /// FT8-like transmission starting 0.5 s into a slot is FT8; the same audio said to start 7 s
    /// later in the minute is not (its onset is then mid-slot). FT8 gets no streaming decoder.
    @Test func classifierUsesSampleTimes() {
        let audio = noisy(ft8Like(baseHz: 1_000, start: 0.5, seconds: 15, seed: 918), snrDb: 10, seed: 918)
        let slotStart = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 60) + 15)
        func run(startingAt t0: Date) -> (ModemEngine, Run) {
            let engine = ModemEngine()
            engine.settings = ModemSettings(mode: .psk31, autoDetect: true)
            var run = Run()
            var start = 0
            while start < audio.count {
                let end = min(start + 1_200, audio.count)
                let out = audio[start..<end].withUnsafeBufferPointer {
                    engine.process($0, sampleIndex: start, firstSampleTime: t0.addingTimeInterval(Double(start) / fs))
                }
                if let s = out.signals { run.signals = s }
                for t in out.text { run.text[t.trackID, default: ""] += t.text }
                start = end
            }
            return (engine, run)
        }
        let (aligned, alignedRun) = run(startingAt: slotStart)
        let s = alignedRun.signals?.first { abs($0.frequencyHz - 1_021.875) < 15 }
        #expect(s?.mode == .ft8, "\(String(describing: alignedRun.signals))")
        #expect(aligned.classification(ofTrack: s?.id ?? 0).map { $0.confidence >= 0.5 } == true)
        #expect(aligned.decoderKeys.isEmpty)
        #expect(alignedRun.text.isEmpty)
        let (late, lateRun) = run(startingAt: slotStart.addingTimeInterval(7))
        let l = lateRun.signals?.first { abs($0.frequencyHz - 1_021.875) < 15 }
        #expect(l != nil && l?.mode != .ft8, "\(String(describing: lateRun.signals))")
        #expect(late.classification(ofTrack: l?.id ?? 0)?.mode != .ft8)
    }

    @Test func processRecordsTimedBlocksForSlots() {
        let engine = ModemEngine()
        engine.settings = ModemSettings(mode: .ft8)
        let audio = ModemTestSignals.noise(seconds: 1, seed: 916)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for start in stride(from: 0, to: audio.count, by: 3_000) {
            let time = t0.addingTimeInterval(Double(start) / fs)
            _ = audio[start..<(start + 3_000)].withUnsafeBufferPointer { engine.process($0, sampleIndex: start, firstSampleTime: time) }
        }
        // Four timed blocks make one continuous run; an untimed block is not recorded.
        #expect(engine.slotRecorder.retainedSampleCount == 12_000)
        #expect(engine.slotRecorder.anchorCount == 1)
        _ = audio[0..<100].withUnsafeBufferPointer { engine.process($0, sampleIndex: 12_000) }
        #expect(engine.slotRecorder.retainedSampleCount == 12_000)
        #expect(engine.decoderKeys.isEmpty, "a slot mode runs no streaming decoders")
    }
}
