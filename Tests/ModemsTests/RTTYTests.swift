import Testing
import Foundation
import DSPCore
@testable import Modems

private let text = "RYRYRY CQ TEST DE OH2XX OH2XX 599 001 K"
private let otherText = "CQ CQ DE G3XYZ G3XYZ PSE K QTH LONDON NAME JIM 73"
private let leadIn = 1.0
/// RTTY is constant-envelope: its burst power is amplitude²/2 (ruling R7).
private let rttyPower = 0.5 * 0.5 / 2

private func run(_ decoder: any SignalDecoder, _ audio: [Float], chunk: Int = 1_024) -> String {
    var out = ""
    for start in stride(from: 0, to: audio.count, by: chunk) {
        audio[start..<min(start + chunk, audio.count)].withUnsafeBufferPointer { out += decoder.process($0) }
    }
    return out
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

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

private func accuracy(_ received: String, sent: String = text) -> Double {
    ModemTestSignals.characterAccuracy(sent: sent, received: trimmed(received))
}

private func mixed(_ a: [Float], _ b: [Float]) -> [Float] {
    var out = [Float](repeating: 0, count: max(a.count, b.count))
    for i in 0..<a.count { out[i] += a[i] }
    for i in 0..<b.count { out[i] += b[i] }
    return out
}

private func makeDecoder(_ hz: Double = 1_500) -> any SignalDecoder {
    RTTYModem.makeDecoder(frequencyHz: hz, sampleRate: 12_000)
}

@Suite struct RTTYTests {
    // MARK: - Baudot

    @Test func baudotRoundTrip() {
        let codes = Baudot.encode(text)
        #expect(codes.allSatisfy { $0 < 32 })
        // FIGS before each "2" (LTRS after it), before "5", and again before "0" after the space
        // (unshift on space).
        #expect(codes.filter { $0 == Baudot.figs }.count == 4)
        #expect(codes.filter { $0 == Baudot.ltrs }.count == 2)
        var decoder = Baudot.Decoder()
        let back = String(codes.compactMap { decoder.decode($0) })
        #expect(back == text)
    }

    @Test func baudotCoversBothShifts() {
        let all = "ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 -?:$!&#'(),./;\""
        var decoder = Baudot.Decoder()
        #expect(String(Baudot.encode(all).compactMap { decoder.decode($0) }) == all)
        // Spot checks against ITA2: E = 10000, A = 11000, T = 00001, Y = 10101 (bit 1 first).
        #expect(Baudot.encode("E") == [1])
        #expect(Baudot.encode("A") == [3])
        #expect(Baudot.encode("T") == [16])
        #expect(Baudot.encode("RY") == [10, 21])
        // Lower case is sent upper case; characters ITA2 lacks are skipped; a newline is CR LF.
        #expect(Baudot.encode("e*t\n") == [1, 16, 8, 2])
        // Without unshift-on-space a figure after a space needs no second FIGS.
        var plain = Baudot.Decoder(unshiftOnSpace: false)
        let codes = Baudot.encode("5 5", unshiftOnSpace: false)
        #expect(codes == [Baudot.figs, 16, 4, 16])
        #expect(String(codes.compactMap { plain.decode($0) }) == "5 5")
        // With it, the receiver is back in letters after the space.
        var usos = Baudot.Decoder()
        #expect(String(codes.compactMap { usos.decode($0) }) == "5 T")
    }

    @Test func encoderTiming() {
        let rate = 12_000.0
        let audio = RTTYEncoder.audio(text: "E", centerHz: 1_500, leadInSeconds: 0)
        // Idle 8 bits, LTRS and E (7.5 bits each), idle 8 bits.
        let bits = 8 + 7.5 * 2 + 8
        #expect(abs(Double(audio.count) - bits / 45.45 * rate) <= 1)
        #expect(RTTYEncoder.keying(codes: [1]).count == Int(2 * (8 + 7.5 + 8)))
    }

    // MARK: - Decoding

    @Test func catalogHasRTTY() {
        #expect(ModemCatalog.streaming(.rtty) != nil)
        #expect(RTTYModem.id == .rtty)
        let decoder = makeDecoder()
        #expect(decoder.submode == "RTTY 45")
        #expect(decoder.frequencyHz == 1_500)
    }

    @Test func cleanDecode() {
        let clear = RTTYEncoder.audio(text: text, centerHz: 1_500)
        let results = parallel(20) { i in
            let audio = ModemTestSignals.awgn(clear, snrDb: 10, seed: UInt64(4001 + i), signalPower: rttyPower)
            let decoder = makeDecoder()
            return (run(decoder, audio), decoder.submode)
        }
        for (i, (out, submode)) in results.enumerated() {
            #expect(accuracy(out) == 1.0, "seed \(4001 + i): '\(out)'")
            #expect(submode == "RTTY 45")
        }
    }

    /// The plan's gate: seeds 1...5 (parameters were tuned on seeds 101...160 only).
    @Test func minus5dB() {
        let clear = RTTYEncoder.audio(text: text, centerHz: 1_500)
        let accs = parallel(5) { i in
            let audio = ModemTestSignals.awgn(clear, snrDb: -5, seed: UInt64(1 + i), signalPower: rttyPower)
            return accuracy(run(makeDecoder(), audio))
        }
        let mean = accs.reduce(0, +) / Double(accs.count)
        #expect(mean >= 0.95, "mean accuracy \(mean), all \(accs)")
    }

    /// R10: the same gate over 20 more held-out seeds.
    @Test func minus5dBHeldOut() {
        let clear = RTTYEncoder.audio(text: text, centerHz: 1_500)
        let accs = parallel(20) { i in
            let audio = ModemTestSignals.awgn(clear, snrDb: -5, seed: UInt64(1001 + i), signalPower: rttyPower)
            return accuracy(run(makeDecoder(), audio))
        }
        let mean = accs.reduce(0, +) / Double(accs.count)
        #expect(mean >= 0.95, "mean accuracy \(mean), all \(accs)")
    }

    /// The engine builds decoders at the tracker's centre estimate, a few Hz off: −5 dB still decodes.
    @Test(arguments: [-6.0, 6.0])
    func minus5dBWithTrackerError(_ offset: Double) {
        let clear = RTTYEncoder.audio(text: text, centerHz: 1_500 + offset)
        let accs = parallel(10) { i in
            let audio = ModemTestSignals.awgn(clear, snrDb: -5, seed: UInt64(1101 + i), signalPower: rttyPower)
            return accuracy(run(makeDecoder(), audio))
        }
        let mean = accs.reduce(0, +) / Double(accs.count)
        #expect(mean >= 0.95, "mean accuracy \(mean), all \(accs)")
    }

    /// Reverse shift (mark the lower tone) is detected on its own within 3 s of the signal's start,
    /// and the whole text decodes, including what was received before the flip.
    @Test func reverseShiftAutoDetected() {
        let rate = 12_000.0
        let clear = RTTYEncoder.audio(text: text, centerHz: 1_500, reverse: true)
        let results = parallel(10) { i in
            let audio = ModemTestSignals.awgn(clear, snrDb: 10, seed: UInt64(4101 + i), signalPower: rttyPower)
            let decoder = RTTYSignalDecoder(frequencyHz: 1_500, sampleRate: rate)
            var out = ""
            var flippedAt = Double.infinity
            let chunk = 240
            for start in stride(from: 0, to: audio.count, by: chunk) {
                audio[start..<min(start + chunk, audio.count)].withUnsafeBufferPointer { out += decoder.process($0) }
                if decoder.isReversed && flippedAt.isInfinite { flippedAt = Double(start + chunk) / rate }
            }
            return (out, flippedAt, decoder.isReversed)
        }
        for (i, (out, flippedAt, reversed)) in results.enumerated() {
            #expect(accuracy(out) == 1.0, "seed \(4101 + i): '\(out)'")
            #expect(reversed)
            #expect(flippedAt - leadIn <= 3, "seed \(4101 + i): flipped \(flippedAt - leadIn) s after the start")
        }
    }

    /// ATC: the upper tone 6 dB down for good, at 0 dB (held-out seeds; tuned on 101...130).
    @Test func weakToneDecodes() {
        let clear = RTTYEncoder.audio(text: text, centerAt: { _ in 1_500 }, upperToneGain: { _ in 0.5 })
        let accs = parallel(10) { i in
            let audio = ModemTestSignals.awgn(clear, snrDb: 0, seed: UInt64(6001 + i), signalPower: rttyPower)
            return accuracy(run(makeDecoder(), audio))
        }
        let mean = accs.reduce(0, +) / Double(accs.count)
        #expect(mean >= 0.95, "mean accuracy \(mean), all \(accs)")
    }

    /// ATC: a slow selective fade takes the upper tone to −20 dB and back every 6 s, at +5 dB; plain
    /// `m − s` reaches only about 0.75 here (held-out seeds; tuned on 101...130).
    @Test func slowSelectiveFadeDecodes() {
        let clear = RTTYEncoder.audio(text: text, centerAt: { _ in 1_500 },
                                      upperToneGain: { t in Float(0.55 + 0.45 * cos(2 * .pi * t / 6)) })
        let accs = parallel(10) { i in
            let audio = ModemTestSignals.awgn(clear, snrDb: 5, seed: UInt64(6101 + i), signalPower: rttyPower)
            return accuracy(run(makeDecoder(), audio))
        }
        let mean = accs.reduce(0, +) / Double(accs.count)
        #expect(mean >= 0.95, "mean accuracy \(mean), all \(accs)")
    }

    /// Normal polarity is never taken for reverse.
    @Test func normalShiftNeverFlips() {
        let clear = RTTYEncoder.audio(text: text + " " + otherText, centerHz: 1_500)
        let flips = parallel(10) { i in
            let audio = ModemTestSignals.awgn(clear, snrDb: i < 5 ? 10 : -5, seed: UInt64(4201 + i), signalPower: rttyPower)
            let decoder = RTTYSignalDecoder(frequencyHz: 1_500, sampleRate: 12_000)
            var flipped = false
            for start in stride(from: 0, to: audio.count, by: 1_024) {
                audio[start..<min(start + 1_024, audio.count)].withUnsafeBufferPointer { _ = decoder.process($0) }
                flipped = flipped || decoder.isReversed
            }
            return flipped
        }
        #expect(flips.filter { $0 }.isEmpty, "flipped in \(flips.filter { $0 }.count) of 10")
    }

    @Test func noiseOnly() {
        let outs = parallel(5) { i in
            run(makeDecoder(), ModemTestSignals.noise(seconds: 60, seed: UInt64(1 + i)))
        }
        for (i, out) in outs.enumerated() {
            #expect(out.filter { !$0.isWhitespace }.isEmpty, "seed \(i + 1): '\(out)'")
            #expect(out.count <= 2, "seed \(i + 1): '\(out)'")
        }
        // Strong noise (sigma 0.5) as well.
        let loud = run(makeDecoder(), ModemTestSignals.noise(seconds: 60, sigma: 0.5, seed: 105))
        #expect(loud.filter { !$0.isWhitespace }.isEmpty, "'\(loud)'")
    }

    /// The AFC pulls in from anywhere in the ±30 Hz RTTY lock range, and `frequencyHz` reports the
    /// signal's centre (midway between mark and space).
    @Test(arguments: [-28.0, -15.0, 15.0, 28.0])
    func afcPullsInWithinLockRange(_ offset: Double) {
        let clear = RTTYEncoder.audio(text: text, centerHz: 1_500 + offset)
        let results = parallel(6) { i in
            let audio = ModemTestSignals.awgn(clear, snrDb: 10, seed: UInt64(5001 + i), signalPower: rttyPower)
            let decoder = makeDecoder()
            return (accuracy(run(decoder, audio)), decoder.frequencyHz)
        }
        for (acc, f) in results {
            #expect(acc == 1.0, "accuracy \(acc)")
            #expect(abs(f - (1_500 + offset)) < 1.5, "tuned to \(f)")
        }
    }

    /// The carrier drifts 0.5 Hz/s for 40 s, from 10 Hz below the decoder's frequency to 10 Hz above.
    @Test func afcFollowsDrift() {
        var sent = ""
        while Double(Baudot.encode(sent).count) * 7.5 / 45.45 < 42 { sent += (sent.isEmpty ? "" : " ") + text }
        let start = 1_490.0, drift = 0.5
        let clear = RTTYEncoder.audio(text: sent, centerAt: { t in start + drift * min(max(t - leadIn, 0), 40) })
        let results = parallel(6) { [sent] i in
            let audio = ModemTestSignals.awgn(clear, snrDb: 0, seed: UInt64(5101 + i), signalPower: rttyPower)
            let decoder = makeDecoder()
            return (accuracy(run(decoder, audio), sent: sent), decoder.frequencyHz)
        }
        let mean = results.map(\.0).reduce(0, +) / Double(results.count)
        #expect(mean >= 0.95, "mean \(mean), all \(results.map(\.0))")
        for (_, f) in results { #expect(abs(f - 1_510) < 2, "tuned to \(f)") }
    }

    /// A decoder beside a signal it may not lock (outside ±30 Hz) stays silent: neither a sideband
    /// leak nor one tone of it is decoded as text, even when it is strong.
    @Test(arguments: [-170.0, -85.0, -60.0, -45.0, 45.0, 60.0, 85.0, 170.0])
    func neighbourOutsideLockRangeIsSilent(_ offset: Double) {
        let other = RTTYEncoder.audio(text: otherText, centerHz: 1_500 + offset)
        let outs = parallel(4) { i in
            let audio = ModemTestSignals.awgn(other, snrDb: i < 2 ? 10 : 30, seed: UInt64(5201 + i), signalPower: rttyPower)
            return run(makeDecoder(), audio)
        }
        for out in outs { #expect(out.filter { !$0.isWhitespace }.count <= 2, "'\(out)'") }
    }

    /// Two RTTY signals 250 Hz apart each decode on their own decoder, without the other's text.
    @Test func twoSignalsDecodeIndependently() {
        let a = RTTYEncoder.audio(text: text, centerHz: 1_200)
        let b = RTTYEncoder.audio(text: otherText, centerHz: 1_450, reverse: true, leadInSeconds: 0.6)
        let outs = parallel(4) { i in
            let audio = ModemTestSignals.awgn(mixed(a, b), snrDb: 5, seed: UInt64(5301 + i), signalPower: rttyPower)
            return (run(makeDecoder(1_200), audio), run(makeDecoder(1_450), audio))
        }
        for (ta, tb) in outs {
            #expect(accuracy(ta) >= 0.95, "'\(ta)'")
            #expect(accuracy(tb, sent: otherText) >= 0.95, "'\(tb)'")
            for word in ["G3XYZ", "LONDON", "JIM"] { #expect(!ta.contains(word), "'\(ta)'") }
            for word in ["OH2XX", "TEST", "RYRY"] { #expect(!tb.contains(word), "'\(tb)'") }
        }
    }

    /// A keyed carrier (CW) on the mark tone, on the space tone or at the centre is not RTTY.
    @Test(arguments: [85.0, -85.0, 0.0])
    func silentOnCW(_ offset: Double) {
        let rate = 12_000.0
        let unit = Int(MorseCode.dotSeconds(wpm: 20) * rate)
        var keyed = [Bool](repeating: false, count: Int(rate * 0.5))
        while keyed.count < Int(20 * rate) {
            for e in MorseCode.timeline(for: "CQ CQ DE W1AW W1AW K TEST 5NN ") {
                keyed += Array(repeating: e.on, count: e.units * unit)
            }
        }
        let hz = 1_500 + offset
        let cw = keyed.enumerated().map { j, on in on ? Float(0.5 * sin(2 * Double.pi * hz * Double(j) / rate)) : 0 }
        let outs = parallel(4) { i in
            run(makeDecoder(), ModemTestSignals.awgn(cw, snrDb: i < 2 ? 10 : 30, seed: UInt64(5401 + i), signalPower: rttyPower))
        }
        for out in outs { #expect(out.filter { !$0.isWhitespace }.count <= 2, "'\(out)'") }
    }

    /// Mark/space envelope pairs at the bit decisions sit at (1, 0) and (0, 1).
    @Test(arguments: [UInt64(4301), 4302, 4303])
    func constellationShowsMarkAndSpace(_ seed: UInt64) {
        let clear = RTTYEncoder.audio(text: text, centerHz: 1_500)
        let decoder = makeDecoder()
        _ = run(decoder, ModemTestSignals.awgn(clear, snrDb: 10, seed: seed, signalPower: rttyPower))
        let points = decoder.constellation()
        #expect(points.count >= 64)
        let marks = points.filter { $0.x > $0.y }, spaces = points.filter { $0.x <= $0.y }
        #expect(marks.count >= 16 && spaces.count >= 16)
        for p in marks { #expect(((p - SIMD2(1, 0)) * (p - SIMD2(1, 0))).sum().squareRoot() <= 0.35, "\(p)") }
        for p in spaces { #expect(((p - SIMD2(0, 1)) * (p - SIMD2(0, 1))).sum().squareRoot() <= 0.35, "\(p)") }
    }

    @Test(arguments: [UInt64(4401), 4402, 4403])
    func chunkSizeIndependent(_ seed: UInt64) {
        let clear = RTTYEncoder.audio(text: text, centerHz: 1_508)
        let audio = ModemTestSignals.awgn(clear, snrDb: -3, seed: seed, signalPower: rttyPower)
        let a = makeDecoder(), b = makeDecoder()
        let textA = run(a, audio, chunk: 37), textB = run(b, audio, chunk: 4_096)
        #expect(textA == textB)
        #expect(a.frequencyHz == b.frequencyHz)
        #expect(accuracy(textA) >= 0.95, "got '\(textA)'")
    }

    @Test func resetRestoresInitialState() {
        let clear = RTTYEncoder.audio(text: text, centerHz: 1_510, reverse: true)
        let audio = ModemTestSignals.awgn(clear, snrDb: 10, seed: 9, signalPower: rttyPower)
        let decoder = RTTYSignalDecoder(frequencyHz: 1_500, sampleRate: 12_000)
        let first = run(decoder, audio)
        #expect(decoder.isReversed)
        #expect(decoder.frequencyHz != 1_500)
        #expect(!decoder.constellation().isEmpty)
        decoder.reset()
        #expect(!decoder.isReversed)
        #expect(decoder.frequencyHz == 1_500)
        #expect(decoder.constellation().isEmpty)
        #expect(run(decoder, audio) == first)
        #expect(accuracy(first) == 1.0, "got '\(first)'")
    }
}
