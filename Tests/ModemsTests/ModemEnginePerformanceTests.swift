import Testing
import Foundation
@testable import Modems

// The CPU budget of spec §8: the modem engine with 30 active PSK31 decoders, plus FT8 slot decoding,
// must leave real-time headroom. All audio is 12 kHz box audio. SNRs follow ruling R7: the noise is set
// once from the in-burst power of a PSK31 signal of amplitude 0.5, and every signal's level is set
// relative to it.
//
// The timings mean something only in an optimised build, so the tests run only in one (`swift test -c
// release`); a debug run skips them with a message. On the Linux check harness the FFTs come from a
// pure-Swift stand-in for Accelerate, slower than vDSP, so the figures there are conservative.

private let fs = 12_000.0

/// True in an optimised build (`-O`, `-Osize`, `-Ounchecked`): `_isDebugAssertConfiguration()` is the
/// standard library's own test of `-Onone`, evaluated in this (the test) module.
private let isOptimizedBuild = !_isDebugAssertConfiguration()

// MARK: - Signals

/// Mean square of `x` after `leadIn` seconds: a PSK31 signal's in-burst power (rulings R7, R12).
private func burstPower(_ x: [Float], leadIn: Double) -> Double {
    let tail = x[Int(leadIn * fs)...]
    return tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(tail.count, 1))
}

/// PSK31 burst power at amplitude 0.5, the noise reference.
private let pskPower = burstPower(PSK31Encoder.audio(text: "the quick brown fox jumps over the lazy dog",
                                                     frequencyHz: 1_500, leadInSeconds: 1, amplitude: 0.5), leadIn: 1)

/// The PSK31 amplitude that puts a signal `db` above (or below) one of amplitude 0.5.
private func pskAmplitude(_ db: Double) -> Float { Float(0.5 * pow(10, db / 20)) }

private func addInto(_ out: inout [Float], _ x: [Float]) {
    for i in x.indices where i < out.count { out[i] += x[i] }
}

private let words = ["cq", "de", "pse", "k", "tnx", "fer", "call", "ur", "rst", "599", "name", "qth", "rig", "ant",
                     "dipole", "yagi", "wx", "sunny", "rain", "cold", "band", "open", "good", "condx", "hw", "cpy",
                     "73", "es", "gl", "dx", "psk", "fifty", "watts", "home", "made", "station", "today", "here",
                     "is", "the", "and", "very", "nice", "to", "meet", "you", "again", "on", "twenty", "meters"]

/// Thirty distinct texts of about 140 characters (some 38 s of PSK31 each), seeded.
private let texts: [String] = (0..<30).map { k in
    var state = UInt64(k) &* 2_654_435_761 &+ 17
    var s = "cq de stn\(k) stn\(k)"
    while s.count < 140 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        s += " " + words[Int(state >> 33) % words.count]
    }
    return s
}

/// The 30 signals: 100 Hz apart from 350 to 3250 Hz with a ±4 Hz offset (so 92 Hz or more apart),
/// levels 0…+15 dB in a shuffled order, start times 0.5…11.8 s.
private let signals: [(hz: Double, db: Double, leadIn: Double)] = (0..<30).map { k in
    let hz: Double = 350 + 100 * Double(k) + Double((k * 7) % 9 - 4)
    let db: Double = 15 * Double((k * 11) % 30) / 29
    let leadIn: Double = 0.5 + Double((k * 13) % 30) * 0.39
    return (hz: hz, db: db, leadIn: leadIn)
}

/// 60 s of the 30 signals in noise.
private func busyBand(seconds: Double = 60) -> [Float] {
    var audio = [Float](repeating: 0, count: Int(seconds * fs))
    for (text, s) in zip(texts, signals) {
        addInto(&audio, PSK31Encoder.audio(text: text, frequencyHz: s.hz, leadInSeconds: s.leadIn, amplitude: pskAmplitude(s.db)))
    }
    return ModemTestSignals.awgn(audio, snrDb: 0, seed: 1_701, signalPower: pskPower)
}

private let ft8Messages = ["CQ W1AW FN31", "CQ K1ABC FN42", "G3PLX W1AW -12", "W1AW G3PLX R-08", "OH2XX K1ABC RR73",
                           "CQ DX JA1XYZ PM95", "K1ABC OH2XX KP20", "VK2ABC ZL1XY 73", "CQ DL1ABC JO62", "F5ABC DL1ABC -05",
                           "CQ EA3XYZ JN11", "EA3XYZ F5ABC JN18", "CQ VE3ABC FN03", "K9XYZ VE3ABC RR73", "CQ PY2ABC GG66",
                           "I2ABC PY2ABC -15", "CQ ZS6ABC KG33", "CQ 9A1ABC JN75", "SP3ABC 9A1ABC R+02", "CQ UA3ABC KO85"]

/// A busy 15 s FT8 slot: 20 signals 140 Hz apart from 300 Hz, at −16…+10 dB (FT8 is constant-envelope:
/// the reference is amplitude²/2 of one signal at 0.5, ruling R7), with start offsets −0.2…+0.5 s.
private func busySlot(seed: UInt64) -> [Float] {
    var audio = [Float](repeating: 0, count: Int(15 * fs))
    for (k, message) in ft8Messages.enumerated() {
        let db = -16 + 26 * Double((k * 7) % 20) / 19
        let a = Float(0.5 * pow(10, db / 20))
        let tx = FT8Encoder.audio(message: message, audioHz: 300 + 140 * Double(k) + 0.6, amplitude: a)!
        let d = Int((-0.2 + 0.1 * Double(k % 8)) * fs)
        for i in audio.indices where tx.indices.contains(i - d) { audio[i] += tx[i - d] }
    }
    return ModemTestSignals.awgn(audio, snrDb: 0, seed: seed, signalPower: 0.5 * 0.5 / 2)
}

// MARK: - Running

private struct Result {
    var elapsed: Double
    var accuracies: [Double]
    var decoders: Int
}

/// Feeds `audio` to an engine set up as the app's default (PSK31 with auto-detect) in the app's
/// 2048-sample blocks, with UTC times so the slot recorder runs too. Times the feeding only.
private func runEngine(_ audio: [Float]) -> Result {
    let engine = ModemEngine()
    engine.settings = ModemSettings(mode: .psk31, autoDetect: true)
    var text: [Int: String] = [:]
    var lastSignals: [SignalSnapshot] = []
    var decoders = 0
    let t0 = Date()
    var start = 0
    while start < audio.count {
        let end = min(start + 2_048, audio.count)
        let time = Date(timeIntervalSince1970: 1_800_000_000 + Double(start) / fs)
        let out = audio[start..<end].withUnsafeBufferPointer { engine.process($0, sampleIndex: start, firstSampleTime: time) }
        for t in out.text { text[t.trackID, default: ""] += t.text }
        if let s = out.signals { lastSignals = s }
        decoders = max(decoders, engine.decoderKeys.count)
        start = end
    }
    let elapsed = Date().timeIntervalSince(t0)
    let accuracies = zip(texts, signals).map { sent, s -> Double in
        let near = lastSignals.filter { abs($0.frequencyHz - s.hz) <= 5 }
        let got = near.map { text[$0.id] ?? "" }.max { $0.count < $1.count } ?? ""
        return ModemTestSignals.characterAccuracy(sent: sent, received: got.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return Result(elapsed: elapsed, accuracies: accuracies, decoders: decoders)
}

private func report(_ label: String, _ r: Result, seconds: Double = 60) {
    let good = r.accuracies.filter { $0 >= 0.9 }.count
    print("\(label): \(String(format: "%.3f", r.elapsed)) s for \(Int(seconds)) s of audio, real-time factor "
          + "\(String(format: "%.4f", r.elapsed / seconds)) (\(String(format: "%.1f", seconds / r.elapsed))x real time), "
          + "at most \(r.decoders) decoders, \(good)/30 signals at >= 0.9 accuracy, accuracies "
          + r.accuracies.map { String(format: "%.2f", $0) }.joined(separator: " "))
}

/// Results of a background job, filled under a lock.
private final class Box<T>: @unchecked Sendable {
    var value: T?
    let lock = NSLock()
}

// MARK: - Tests

@Suite(.serialized) struct ModemEnginePerformanceTests {
    /// 60 s with 30 PSK31 signals through the engine in < 6 s (≥ 10× real time), and decoded.
    @Test(.enabled(if: isOptimizedBuild, "timing test: runs only in an optimised build (swift test -c release)"))
    func thirtyPSKDecodersRealtimeHeadroom() {
        let audio = busyBand()
        let r = runEngine(audio)
        report("thirtyPSKDecodersRealtimeHeadroom", r)
        #expect(r.elapsed < 6, "\(r.elapsed) s for 60 s of audio")
        #expect(r.decoders >= 30, "only \(r.decoders) decoders ran at once")
        let good = r.accuracies.filter { $0 >= 0.9 }.count
        #expect(good >= 28, "\(good)/30 signals at >= 0.9: \(r.accuracies)")
    }

    /// The spec's whole CPU target: the same 60 s through the engine while, on another thread (as the
    /// app's slot queue does), FT8 decodes four busy slots. Both finish in < 6 s, and the slots decode.
    @Test(.enabled(if: isOptimizedBuild, "timing test: runs only in an optimised build (swift test -c release)"))
    func thirtyPSKDecodersPlusFT8() {
        let audio = busyBand()
        let slots = (0..<4).map { busySlot(seed: 1_710 + UInt64($0)) }

        // FT8 alone first: the time of one busy slot.
        let a0 = Date()
        let alone = FT8Modem.decode(samples: slots[0], sampleRate: fs, slotStart: Date(timeIntervalSince1970: 0),
                                    audioBand: 200...3_300)
        let aloneTime = Date().timeIntervalSince(a0)

        let ft8 = Box<(Double, [Int])>()
        let done = DispatchSemaphore(value: 0)
        let t0 = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            var counts: [Int] = []
            for slot in slots {
                counts.append(FT8Modem.decode(samples: slot, sampleRate: fs, slotStart: Date(timeIntervalSince1970: 0),
                                              audioBand: 200...3_300).filter { ft8Messages.contains($0.message) }.count)
            }
            ft8.lock.lock(); ft8.value = (Date().timeIntervalSince(t0), counts); ft8.lock.unlock()
            done.signal()
        }
        let r = runEngine(audio)
        done.wait()
        let total = Date().timeIntervalSince(t0)
        let (ft8Time, counts) = ft8.value!
        report("thirtyPSKDecodersPlusFT8 (engine, FT8 concurrent)", r)
        print("thirtyPSKDecodersPlusFT8: FT8 one busy slot alone \(String(format: "%.3f", aloneTime)) s "
              + "(\(alone.count) decodes of 20); four slots concurrent with the engine \(String(format: "%.3f", ft8Time)) s "
              + "(\(counts) decodes of 20 each); total wall \(String(format: "%.3f", total)) s")
        #expect(total < 6, "\(total) s for 60 s of audio and four FT8 slots")
        #expect(aloneTime < 3, "one busy FT8 slot took \(aloneTime) s")
        #expect(counts.allSatisfy { $0 >= 18 }, "\(counts)")
        #expect(r.accuracies.filter { $0 >= 0.9 }.count >= 28)
    }
}
