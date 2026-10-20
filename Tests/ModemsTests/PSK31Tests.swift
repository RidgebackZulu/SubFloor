import Testing
import Foundation
import DSPCore
@testable import Modems

private let text = "the quick brown fox JUMPS over the lazy dog 0123456789 CQ CQ DE W1AW PSE K"
private let leadIn = 1.0

/// Mean power of the PSK31 signal while it transmits (ruling R7): the mean square of everything
/// after the lead-in silence, so the SNR is not diluted by the gap.
private func burstPower(_ audio: [Float], leadIn: Double = leadIn, rate: Double = 12_000) -> Double {
    let start = Int(leadIn * rate)
    let tail = audio[start...]
    return tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tail.count)
}

private func run(_ decoder: any SignalDecoder, _ audio: [Float], chunk: Int = 1_024) -> String {
    var out = ""
    for start in stride(from: 0, to: audio.count, by: chunk) {
        audio[start..<min(start + chunk, audio.count)].withUnsafeBufferPointer { out += decoder.process($0) }
    }
    return out
}

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

private func accuracy(_ received: String) -> Double {
    ModemTestSignals.characterAccuracy(sent: text, received: trimmed(received))
}

// MARK: - Varicode

@Test func varicodeRoundTrip() {
    for code in 0...127 {
        let c = Character(Unicode.Scalar(UInt8(code)))
        let bits = Varicode.encode(c)
        #expect(!bits.isEmpty)
        #expect(Varicode.decode(bits) == c, "code \(code)")
    }
    #expect(Varicode.encode("e") == [true, true])
    #expect(Varicode.encode(" ") == [true])
}

/// Structural check of the G3PLX table: every code starts and ends with 1, has no "00" inside, and
/// the 128 codes are exactly the 88 such words of up to 9 bits plus 40 of the 55 10-bit words.
@Test func varicodeTableIsTheCompleteG3PLXAlphabet() {
    var lengths = [Int: Int]()
    var seen = Set<[Bool]>()
    for code in 0...127 {
        let bits = Varicode.encode(Character(Unicode.Scalar(UInt8(code))))
        #expect(bits.first == true && bits.last == true)
        #expect(!zip(bits, bits.dropFirst()).contains { !$0 && !$1 })
        #expect(seen.insert(bits).inserted)
        lengths[bits.count, default: 0] += 1
    }
    #expect(lengths == [1: 1, 2: 1, 3: 2, 4: 3, 5: 5, 6: 8, 7: 13, 8: 21, 9: 34, 10: 40])
    // Spot checks against G3PLX, QEX July/Aug 1999, Table 1.
    let published: [Character: String] = [
        "\0": "1010101011", "\n": "11101", "\r": "11111", "a": "1011", "t": "101", "o": "111",
        "W": "101011101", "X": "101110101", "Z": "1010101101", "`": "1011011111", "_": "101101101",
        "\u{7F}": "1110110101", "~": "1011010111", "0": "10110111", "?": "1010101111",
    ]
    for (c, bits) in published {
        #expect(Varicode.encode(c).map { $0 ? "1" : "0" }.joined() == bits, "\(c.unicodeScalars.first!.value)")
    }
    #expect(Varicode.decode([true, false, true, false, true, true, true, true, true, true, true]) == nil)
}

// MARK: - QPSK convolutional code

/// The G3PLX sidebar "The Convolutional Code" (QEX July/Aug 1999): the phase shift, in quarter turns
/// (1 = advance 90°), for each run of five bits, oldest bit on the left.
@Test func convolutionalCodeMatchesG3PLXTable() {
    let table: [String: Int] = [
        "00000": 2, "01000": 0, "10000": 1, "11000": 3, "00001": 1, "01001": 3, "10001": 2, "11001": 0,
        "00010": 3, "01010": 1, "10010": 0, "11010": 2, "00011": 0, "01011": 2, "10011": 3, "11011": 1,
        "00100": 3, "01100": 1, "10100": 0, "11100": 2, "00101": 0, "01101": 2, "10101": 3, "11101": 1,
        "00110": 2, "01110": 0, "10110": 1, "11110": 3, "00111": 1, "01111": 3, "10111": 2, "11111": 0,
    ]
    #expect(table.count == 32)
    for (bits, shift) in table {
        #expect(QPSKCode.phaseShift(window: Int(bits, radix: 2)!) == shift, "\(bits)")
    }
    // The published worked example: the space character (a single 1 between zeros) is 2,1,3,3,0,1,2.
    var window = 0
    var shifts: [Int] = []
    for bit in [false, true, false, false, false, false, false] {
        window = ((window << 1) | (bit ? 1 : 0)) & 31
        shifts.append(QPSKCode.phaseShift(window: window))
    }
    #expect(shifts == [2, 1, 3, 3, 0, 1, 2])
}

@Test func viterbiDecodesCleanAndCorruptedCode() {
    // Deterministic pseudo-random bits (a 32-bit LCG).
    var state: UInt32 = 12_345
    let bits = (0..<400).map { _ -> Bool in
        state = state &* 1_664_525 &+ 1_013_904_223
        return state >> 31 == 1
    }
    var window = 0
    var phases: [Int] = []
    for b in bits {
        window = ((window << 1) | (b ? 1 : 0)) & 31
        phases.append(QPSKCode.phaseShift(window: window))
    }
    // Flip every 15th phase shift to a wrong neighbour: the code must correct isolated errors.
    for corrupt in [false, true] {
        var viterbi = QPSKViterbi()
        var decoded: [Bool] = []
        for (i, p) in phases.enumerated() {
            let shown = corrupt && i % 15 == 7 ? (p + 1) & 3 : p
            let angle = Double(shown) * .pi / 2
            if let b = viterbi.push(SIMD2(Float(cos(angle)), Float(sin(angle)))) { decoded.append(b) }
        }
        #expect(decoded.count == bits.count - QPSKViterbi.delay)
        #expect(Array(bits.prefix(decoded.count)) == decoded, "corrupt: \(corrupt)")
    }
}

// MARK: - Decoding

@Test func catalogHasPSK31() {
    #expect(ModemCatalog.streaming(.psk31) != nil)
    #expect(PSK31Modem.id == .psk31)
}

@Test func bpskCleanDecode() {
    let clear = PSK31Encoder.audio(text: text, frequencyHz: 1_500, leadInSeconds: leadIn)
    let audio = ModemTestSignals.awgn(clear, snrDb: 10, seed: 3, signalPower: burstPower(clear))
    let decoder = PSK31Modem.makeDecoder(frequencyHz: 1_500, sampleRate: 12_000)
    let out = run(decoder, audio)
    #expect(accuracy(out) == 1.0, "got '\(out)'")
    #expect(decoder.submode == "BPSK31")
}

/// R10: the -10 dB gate is the mean over held-out seeds; parameters were tuned on seeds 1...80 only.
@Test func bpskMinus10dB() {
    let clear = PSK31Encoder.audio(text: text, frequencyHz: 1_500, leadInSeconds: leadIn)
    let power = burstPower(clear)
    var total = 0.0
    let seeds = 1001...1020
    for seed in seeds {
        let audio = ModemTestSignals.awgn(clear, snrDb: -10, seed: UInt64(seed), signalPower: power)
        total += accuracy(run(PSK31Modem.makeDecoder(frequencyHz: 1_500, sampleRate: 12_000), audio))
    }
    let mean = total / Double(seeds.count)
    #expect(mean >= 0.95, "mean accuracy \(mean)")
}

@Test func qpskCleanDecode() {
    let clear = PSK31Encoder.audio(text: text, frequencyHz: 1_200, qpsk: true, leadInSeconds: leadIn)
    let audio = ModemTestSignals.awgn(clear, snrDb: 10, seed: 4, signalPower: burstPower(clear))
    let decoder = PSK31Modem.makeDecoder(frequencyHz: 1_200, sampleRate: 12_000)
    let out = run(decoder, audio)
    #expect(accuracy(out) == 1.0, "got '\(out)'")
    #expect(decoder.submode == "QPSK31")
}

/// The carrier drifts 0.5 Hz/s for 40 s: 20 Hz in all, from 10 Hz below the decoder's frequency to
/// 10 Hz above, so the whole drift stays inside the ±15 Hz PSK31 lock range.
@Test func afcTracksDrift() {
    let rate = 12_000.0
    var sent = ""
    // At least 40 s of text after the preamble.
    while Double(PSK31Encoder.bits(for: sent).count - PSK31Encoder.preambleSymbols) / 31.25 < 41 {
        sent += (sent.isEmpty ? "" : " ") + text
    }
    let start = 1_490.0, drift = 0.5
    let clear = PSK31Encoder.audio(text: sent, frequencyHz: start, leadInSeconds: leadIn,
                                   frequencyAt: { t in start + drift * min(max(t - leadIn, 0), 40) })
    #expect(Double(clear.count) / rate >= 40 + leadIn)
    let audio = ModemTestSignals.awgn(clear, snrDb: 5, seed: 5, signalPower: burstPower(clear))
    let out = run(PSK31Modem.makeDecoder(frequencyHz: 1_500, sampleRate: rate), audio)
    let acc = ModemTestSignals.characterAccuracy(sent: sent, received: trimmed(out))
    #expect(acc >= 0.95, "accuracy \(acc), got '\(out)'")
}

/// The AFC is unambiguous across the lock range: the decoder starts 12 Hz off either way.
@Test(arguments: [-12.0, 12.0])
func afcAcquiresAtLockRangeEdge(_ offset: Double) {
    let clear = PSK31Encoder.audio(text: text, frequencyHz: 1_000 + offset, leadInSeconds: leadIn)
    let audio = ModemTestSignals.awgn(clear, snrDb: 10, seed: 6, signalPower: burstPower(clear))
    let decoder = PSK31Modem.makeDecoder(frequencyHz: 1_000, sampleRate: 12_000)
    let out = run(decoder, audio)
    #expect(accuracy(out) >= 0.95, "got '\(out)'")
    #expect(abs(decoder.frequencyHz - (1_000 + offset)) < 0.5, "locked at \(decoder.frequencyHz)")
}

@Test func noiseSquelch() {
    for seed in UInt64(1)...5 {
        let audio = ModemTestSignals.noise(seconds: 60, seed: seed)
        let out = run(PSK31Modem.makeDecoder(frequencyHz: 1_500, sampleRate: 12_000), audio)
        #expect(out.filter { !$0.isWhitespace }.isEmpty, "seed \(seed): '\(out)'")
        #expect(out.count <= 2, "seed \(seed): '\(out)'")
    }
}

@Test func constellationClusters() {
    let clear = PSK31Encoder.audio(text: text, frequencyHz: 1_500, leadInSeconds: leadIn)
    let audio = ModemTestSignals.awgn(clear, snrDb: 10, seed: 7, signalPower: burstPower(clear))
    let decoder = PSK31Modem.makeDecoder(frequencyHz: 1_500, sampleRate: 12_000)
    _ = run(decoder, audio)
    let points = decoder.constellation()
    #expect(points.count >= 64)
    // Two clusters: split on the side of the principal axis (the mean of the doubled-angle vectors).
    var axis = SIMD2<Float>(0, 0)
    for p in points {
        axis += SIMD2(p.x * p.x - p.y * p.y, 2 * p.x * p.y)
    }
    let angle = atan2(axis.y, axis.x) / 2
    let dir = SIMD2(cos(angle), sin(angle))
    let a = points.filter { ($0 * dir).sum() >= 0 }, b = points.filter { ($0 * dir).sum() < 0 }
    #expect(!a.isEmpty && !b.isEmpty)
    for cluster in [a, b] where !cluster.isEmpty {
        let centre = cluster.reduce(SIMD2<Float>(0, 0), +) / Float(cluster.count)
        let worst = cluster.map { (($0 - centre) * ($0 - centre)).sum().squareRoot() }.max() ?? 0
        #expect(worst <= 0.35 * (centre * centre).sum().squareRoot(), "worst \(worst), centre \(centre)")
    }
}

/// R10: the lock-range edge at −10 dB, mean over held-out seeds (tuned on seeds 1...80).
@Test(arguments: [-12.0, 12.0])
func bpskMinus10dBAtLockRangeEdge(_ offset: Double) {
    let clear = PSK31Encoder.audio(text: text, frequencyHz: 1_500 + offset, leadInSeconds: leadIn)
    let power = burstPower(clear)
    var total = 0.0
    let seeds = 1001...1020
    for seed in seeds {
        let audio = ModemTestSignals.awgn(clear, snrDb: -10, seed: UInt64(seed), signalPower: power)
        total += accuracy(run(PSK31Modem.makeDecoder(frequencyHz: 1_500, sampleRate: 12_000), audio))
    }
    let mean = total / Double(seeds.count)
    #expect(mean >= 0.95, "mean accuracy \(mean)")
}

private func mixed(_ a: [Float], _ b: [Float], gainDb: Double) -> [Float] {
    let g = Float(pow(10, gainDb / 20))
    var out = [Float](repeating: 0, count: max(a.count, b.count))
    for i in 0..<a.count { out[i] += a[i] }
    for i in 0..<b.count { out[i] += g * b[i] }
    return out
}

private let otherText = "CQ CQ CQ DE G3PLX G3PLX K RRR TU 73 ES GL QRZ? 599 5NN NAME HR IS PETER QTH KENDAL"

/// A busy segment: a neighbour 20 dB stronger only 80 Hz away (tuned on seeds 1...10; held out here).
@Test func strongNeighbour80HzAway() {
    let wanted = PSK31Encoder.audio(text: text, frequencyHz: 1_500, leadInSeconds: leadIn)
    let neighbour = PSK31Encoder.audio(text: otherText, frequencyHz: 1_580, leadInSeconds: 0.3)
    var total = 0.0
    for seed in UInt64(1001)...1005 {
        let audio = ModemTestSignals.awgn(mixed(wanted, neighbour, gainDb: 20), snrDb: 10, seed: seed,
                                          signalPower: burstPower(wanted))
        total += accuracy(run(PSK31Modem.makeDecoder(frequencyHz: 1_500, sampleRate: 12_000), audio))
    }
    #expect(total / 5 >= 0.95, "mean accuracy \(total / 5)")
}

/// A decoder parked beside a signal it cannot lock (outside ±15 Hz) must stay silent, not decode a
/// sideline or one idle tone of it as garbage.
@Test(arguments: [20.0, 24.0, 31.25, -31.25])
func silentBesideSignalOutsideLockRange(_ offset: Double) {
    let other = PSK31Encoder.audio(text: otherText, frequencyHz: 1_500 + offset, leadInSeconds: leadIn)
    for seed in UInt64(1)...3 {
        let audio = ModemTestSignals.awgn(other, snrDb: 10, seed: seed, signalPower: burstPower(other))
        let out = run(PSK31Modem.makeDecoder(frequencyHz: 1_500, sampleRate: 12_000), audio)
        #expect(out.filter { !$0.isWhitespace }.count <= 2, "seed \(seed): '\(out)'")
    }
}

/// CW (a keyed carrier) on a PSK31 decoder must not spill garbage.
@Test(arguments: [15.0, 20.0, 30.0])
func silentOnCW(_ wpm: Double) {
    let rate = 12_000.0
    let unit = Int(MorseCode.dotSeconds(wpm: wpm) * rate)
    var keyed: [Bool] = []
    for _ in 0..<4 {
        for e in MorseCode.timeline(for: "CQ CQ DE W1AW W1AW K TEST 5NN ") { keyed += Array(repeating: e.on, count: e.units * unit) }
    }
    let cw = keyed.enumerated().map { i, on in on ? Float(0.5 * sin(2 * Double.pi * 1_500 * Double(i) / rate)) : 0 }
    for seed in UInt64(1)...3 {
        let audio = ModemTestSignals.awgn(cw, snrDb: 10, seed: seed, signalPower: 0.5 * 0.5 / 2)
        let out = run(PSK31Modem.makeDecoder(frequencyHz: 1_500, sampleRate: rate), audio)
        #expect(out.filter { !$0.isWhitespace }.count <= 2, "seed \(seed): '\(out)'")
    }
}

@Test func chunkSizeIndependent() {
    let clear = PSK31Encoder.audio(text: text, frequencyHz: 1_500, leadInSeconds: leadIn)
    let audio = ModemTestSignals.awgn(clear, snrDb: 0, seed: 8, signalPower: burstPower(clear))
    let a = run(PSK31Modem.makeDecoder(frequencyHz: 1_500, sampleRate: 12_000), audio, chunk: 37)
    let b = run(PSK31Modem.makeDecoder(frequencyHz: 1_500, sampleRate: 12_000), audio, chunk: 4_096)
    #expect(a == b)
    #expect(accuracy(a) >= 0.95, "got '\(a)'")
}

@Test func resetRestoresInitialState() {
    let clear = PSK31Encoder.audio(text: text, frequencyHz: 1_510, qpsk: true, leadInSeconds: leadIn)
    let audio = ModemTestSignals.awgn(clear, snrDb: 10, seed: 9, signalPower: burstPower(clear))
    let decoder = PSK31Modem.makeDecoder(frequencyHz: 1_500, sampleRate: 12_000)
    let first = run(decoder, audio)
    #expect(decoder.submode == "QPSK31")
    decoder.reset()
    #expect(decoder.submode == "BPSK31")
    #expect(decoder.frequencyHz == 1_500)
    #expect(decoder.constellation().isEmpty)
    #expect(run(decoder, audio) == first)
}
