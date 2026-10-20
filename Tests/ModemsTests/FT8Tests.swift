import Testing
import Foundation
@testable import Modems

// All audio is one 15 s slot of 12 kHz box audio. SNRs follow ruling R7: FT8 is constant-envelope, so
// the reference is the steady power amplitude²/2 of one signal, passed explicitly because the slot
// holds silence around the 12.64 s transmission.

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

private let slotStart = Date(timeIntervalSince1970: 1_800_000_015)  // :15 past a UTC minute
private let fullBand: ClosedRange<Double> = 200...3_300
private let amplitude: Float = 0.5
/// Steady power of one FT8 signal of `amplitude` (constant envelope), the SNR reference (ruling R7).
private let signalPower = Double(amplitude * amplitude) / 2

private func ft8(_ message: String, _ hz: Double, amplitude: Float = amplitude, sampleRate: Double = 12_000) -> [Float] {
    FT8Encoder.audio(message: message, audioHz: hz, sampleRate: sampleRate, amplitude: amplitude)!
}

private func sum(_ signals: [[Float]]) -> [Float] {
    var out = signals[0]
    for s in signals.dropFirst() { for i in out.indices { out[i] += s[i] } }
    return out
}

/// `x` delayed by `seconds` (negative: advanced), keeping its length.
private func shifted(_ x: [Float], by seconds: Double) -> [Float] {
    let d = Int((seconds * 12_000).rounded())
    return x.indices.map { i in x.indices.contains(i - d) ? x[i - d] : 0 }
}

private func decode(_ audio: [Float], band: ClosedRange<Double> = fullBand, sampleRate: Double = 12_000) -> [SlotDecode] {
    FT8Modem.decode(samples: audio, sampleRate: sampleRate, slotStart: slotStart, audioBand: band)
}

private let messages = ["CQ W1AW FN31", "CQ K1ABC FN42", "G3PLX W1AW -12", "W1AW G3PLX R-08", "OH2XX K1ABC RR73",
                        "CQ DX JA1XYZ PM95", "K1ABC OH2XX KP20", "VK2ABC ZL1XY 73"]

/// Trial `i` at `snrDb`: one message (cycling through `messages`) at a frequency spread over
/// 400…2900 Hz and a start offset of −0.3…+0.4 s. 1 = the right message (and nothing else), 0 =
/// nothing, −1 = a wrong message among the decodes (or the right one at the wrong frequency).
private func weakTrial(_ i: Int, snrDb: Double, seedBase: UInt64) -> Int {
    let message = messages[i % messages.count]
    let hz = 400 + Double((i * 383) % 2_500) + 0.7
    let dt = -0.3 + Double((i * 7) % 8) / 10
    let audio = ModemTestSignals.awgn(shifted(ft8(message, hz), by: dt), snrDb: snrDb, seed: seedBase + UInt64(i),
                                      signalPower: signalPower)
    let decodes = decode(audio)
    if decodes.contains(where: { $0.message != message || abs($0.frequencyHz - hz) > 3 }) { return -1 }
    return decodes.isEmpty ? 0 : 1
}

@Suite struct FT8Tests {
    @Test func catalogRegistersFT8() {
        #expect(FT8Modem.id == .ft8)
        #expect(FT8Modem.slotSeconds == 15)
        #expect(ModemCatalog.slot(.ft8).map { ObjectIdentifier($0) } == ObjectIdentifier(FT8Modem.self))
        #expect(ModemCatalog.slot(.wspr).map { ObjectIdentifier($0) } == ObjectIdentifier(WSPRModem.self))
    }

    // MARK: Encoder

    @Test func encoderLayout() throws {
        let audio = try #require(FT8Encoder.audio(message: "CQ W1AW FN31", audioHz: 1_000))
        #expect(audio.count == 15 * 12_000)
        // Silence, then 79 × 1920 samples of signal from 0.5 s.
        #expect(audio[0..<6_000].allSatisfy { $0 == 0 })
        #expect(audio[(6_000 + 79 * 1_920)...].allSatisfy { $0 == 0 })
        let body = audio[6_240..<(6_000 + 79 * 1_920 - 240)]
        #expect(abs(body.map { abs($0) }.max()! - amplitude) < 0.01)
        let power = body.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(body.count)
        #expect(abs(power - signalPower) < 0.002, "constant envelope: \(power)")
        #expect(FT8Encoder.audio(message: "THIS IS NOT A VALID FT8 MESSAGE AT ALL", audioHz: 1_000) == nil)
        #expect(FT8Encoder.tones(message: "cq w1aw fn31") == FT8Encoder.tones(message: "CQ W1AW FN31"))
        #expect(FT8Encoder.audio(message: "CQ W1AW FN31", audioHz: 1_000, sampleRate: 0) == nil)
    }

    /// Mid-symbol, the GFSK sits on tone `audioHz + 6.25·tone` (measured by a DFT over the middle half
    /// of each symbol), and the three Costas arrays are where FT8 puts them.
    @Test func encoderTones() throws {
        let tones = try #require(FT8Encoder.tones(message: "CQ K1ABC FN42"))
        #expect(tones.count == 79)
        let costas: [UInt8] = [3, 1, 4, 0, 6, 5, 2]
        #expect(Array(tones[0..<7]) == costas && Array(tones[36..<43]) == costas && Array(tones[72..<79]) == costas)
        let audio = try #require(FT8Encoder.audio(message: "CQ K1ABC FN42", audioHz: 1_234.5))
        var wrong = 0
        for (k, tone) in tones.enumerated() {
            let a = 6_000 + k * 1_920 + 480
            let power = (0..<8).map { t -> Double in
                let w = 2 * Double.pi * (1_234.5 + 6.25 * Double(t)) / 12_000
                var re = 0.0, im = 0.0
                for n in 0..<960 { re += Double(audio[a + n]) * cos(w * Double(n)); im -= Double(audio[a + n]) * sin(w * Double(n)) }
                return re * re + im * im
            }
            if power.indices.max(by: { power[$0] < power[$1] }) != Int(tone) { wrong += 1 }
        }
        #expect(wrong == 0)
    }

    // MARK: Decoding

    @Test func roundTripClean() throws {
        let decodes = decode(ft8("CQ W1AW FN31", 1_200))
        #expect(decodes.count == 1)
        let d = try #require(decodes.first)
        #expect(d.message == "CQ W1AW FN31")
        #expect(d.mode == .ft8)
        #expect(d.slotStart == slotStart)
        #expect(abs(d.frequencyHz - 1_200) <= 3, "\(d.frequencyHz) Hz")
        #expect(abs(d.timeOffset) < 0.02, "dt \(d.timeOffset) s")
    }

    @Test func sixSignalsOneSlot() {
        let sent: [(String, Double)] = [("CQ W1AW FN31", 500), ("CQ K1ABC FN42", 950), ("G3PLX W1AW -12", 1_400),
                                        ("W1AW G3PLX R-08", 1_850), ("OH2XX K1ABC RR73", 2_300),
                                        ("CQ DX JA1XYZ PM95", 2_800)]
        let audio = ModemTestSignals.awgn(sum(sent.map { ft8($0.0, $0.1) }), snrDb: -10, seed: 10,
                                          signalPower: signalPower)
        let decodes = decode(audio)
        print("FT8 six signals at −10 dB: \(decodes.map { "\($0.message) @\(Int($0.frequencyHz)) \($0.snrDb) dB" })")
        #expect(Set(decodes.map(\.message)) == Set(sent.map(\.0)))
        #expect(decodes.count == 6)
        for (message, hz) in sent {
            #expect(decodes.contains { $0.message == message && abs($0.frequencyHz - hz) <= 3 }, "\(message)")
        }
    }

    @Test func minus20dB() {
        let results = parallel(20) { weakTrial($0, snrDb: -20, seedBase: 20_000) }
        let decoded = results.filter { $0 == 1 }.count, wrong = results.filter { $0 == -1 }.count
        print("FT8 at −20 dB: \(decoded)/20 decoded, \(wrong) wrong")
        #expect(decoded >= 16)
        #expect(wrong == 0)
    }

    /// A 0 dB signal with weaker ones 60 Hz either side (their tones 16 Hz from its own): all three
    /// decode in the single pass, the symbol DFTs keeping the strong signal out of the weak ones' tones.
    @Test(arguments: [-10.0, -15.0, -20.0])
    func strongNextToWeak(weakDb: Double) {
        let weak = Float(pow(10, weakDb / 20))
        let audio = ModemTestSignals.awgn(sum([ft8("CQ W1AW FN31", 1_000), ft8("CQ K1ABC FN42", 940, amplitude: amplitude * weak),
                                               ft8("G3PLX W1AW -12", 1_060, amplitude: amplitude * weak)]),
                                          snrDb: 0, seed: 19, signalPower: signalPower)
        let decodes = decode(audio)
        print("FT8 0 dB with \(weakDb) dB neighbours 60 Hz away: \(decodes.map { "\($0.message) \($0.snrDb) dB" })")
        #expect(Set(decodes.map(\.message)) == ["CQ W1AW FN31", "CQ K1ABC FN42", "G3PLX W1AW -12"])
    }

    @Test func bandFilter() {
        let audio = ModemTestSignals.awgn(sum([ft8("CQ W1AW FN31", 800), ft8("CQ K1ABC FN42", 2_000)]), snrDb: -10,
                                          seed: 11, signalPower: signalPower)
        #expect(Set(decode(audio).map(\.message)) == ["CQ W1AW FN31", "CQ K1ABC FN42"])
        #expect(decode(audio, band: 300...1_500).map(\.message) == ["CQ W1AW FN31"])
        #expect(decode(audio, band: 1_500...3_300).map(\.message) == ["CQ K1ABC FN42"])
        #expect(decode(audio, band: 900...1_900).isEmpty)
        // The band bounds tone 0, the reported frequency.
        #expect(decode(audio, band: 790...810).map(\.message) == ["CQ W1AW FN31"])
        #expect(decode(audio, band: 1_990...2_010).map(\.message) == ["CQ K1ABC FN42"])
        #expect(decode(audio, band: 805...1_990).isEmpty)
    }

    @Test(arguments: [-0.8, -0.3, 0.0, 0.25, 1.5])
    func timeOffset(dt: Double) throws {
        let audio = ModemTestSignals.awgn(shifted(ft8("G3PLX W1AW -12", 1_500), by: dt), snrDb: -12, seed: 12,
                                          signalPower: signalPower)
        let decodes = decode(audio)
        let d = try #require(decodes.first)
        #expect(decodes.count == 1)
        #expect(abs(d.timeOffset - dt) < 0.02, "dt \(d.timeOffset) s, sent \(dt) s")
        #expect(abs(d.frequencyHz - 1_500) < 0.5, "\(d.frequencyHz) Hz")
    }

    @Test(arguments: [-18.0, -15.0, -10.0, -5.0, 0.0, 10.0])
    func reportedSNR(snrDb: Double) throws {
        let audio = ModemTestSignals.awgn(ft8("CQ K1ABC FN42", 1_700.3), snrDb: snrDb, seed: 13, signalPower: signalPower)
        let d = try #require(decode(audio).first)
        print("FT8 SNR \(snrDb) dB reported as \(d.snrDb) dB")
        #expect(abs(Double(d.snrDb) - snrDb) <= 1.5, "true \(snrDb) dB, reported \(d.snrDb) dB")
    }

    /// Thirty independent noise slots, half with steady carriers and keyed tones in the band: no decodes.
    @Test func noFalseDecodesOverManyNoiseSlots() {
        let counts = parallel(30) { i -> Int in
            var audio = ModemTestSignals.noise(seconds: 15, seed: 30_000 + UInt64(i))
            if i % 2 == 1 {
                for (k, hz) in [700.0, 1_503.1, 2_250.0].enumerated() {
                    let carrier = ModemTestSignals.tone(hz + Double(i), seconds: 15, amplitude: 0.02 * Float(k + 1))
                    for n in audio.indices { audio[n] += carrier[n] }
                }
                for n in audio.indices where (n / 1_920) % 3 != 0 {
                    audio[n] += 0.05 * Float(sin(2 * Double.pi * 1_812.5 * Double(n) / 12_000))
                }
            }
            return decode(audio).count
        }
        print("FT8 noise slots: decodes per slot \(counts)")
        #expect(counts.allSatisfy { $0 == 0 })
    }

    @Test func shortAndOddSlotSamples() {
        #expect(decode([]).isEmpty)
        #expect(decode([Float](repeating: 0, count: 15 * 12_000)).isEmpty)
        #expect(decode(ModemTestSignals.noise(seconds: 0.5, seed: 14)).isEmpty)
        let full = ModemTestSignals.awgn(ft8("CQ W1AW FN31", 1_000), snrDb: -10, seed: 14, signalPower: signalPower)
        // Ending at the transmission's end (13.14 s), and longer than a slot: both decode.
        #expect(decode(Array(full[..<(13_140 * 12)])).map(\.message) == ["CQ W1AW FN31"])
        #expect(decode(full + ModemTestSignals.noise(seconds: 5, sigma: 0.01, seed: 15)).map(\.message) == ["CQ W1AW FN31"])
        // Truncated to 7 s: no crash (the message may or may not survive).
        #expect(decode(Array(full[..<(7 * 12_000)])).allSatisfy { $0.message == "CQ W1AW FN31" })
        #expect(FT8Modem.decode(samples: full, sampleRate: 0, slotStart: slotStart, audioBand: fullBand).isEmpty)
        #expect(decode(full, band: 999...1_001).map(\.message) == ["CQ W1AW FN31"])
        #expect(decode(full, band: 1_000...1_000).allSatisfy { $0.message == "CQ W1AW FN31" })
        #expect(decode(full, band: 5_000...9_000).isEmpty)
        #expect(decode(full, band: -100...150).isEmpty)
        var corrupt = full
        corrupt[7 * 12_000] = .nan
        #expect(decode(corrupt).allSatisfy { $0.message == "CQ W1AW FN31" })
    }

    @Test func otherSampleRate() {
        let rate = 48_000.0
        let audio = ModemTestSignals.awgn(ft8("CQ K1ABC FN42", 1_470, sampleRate: rate), snrDb: -15, sampleRate: rate,
                                          seed: 16, signalPower: signalPower)
        let decodes = decode(audio, sampleRate: rate)
        #expect(decodes.map(\.message) == ["CQ K1ABC FN42"])
        #expect(decodes.allSatisfy { abs($0.frequencyHz - 1_470) <= 1 && abs($0.timeOffset) < 0.03 })
    }

    /// Decode time per slot (release build), reported for the slot queue's budget.
    @Test func decodeTime() {
        let busy = ModemTestSignals.awgn(sum((0..<8).map { ft8(messages[$0], 400 + 300 * Double($0)) }), snrDb: -15,
                                         seed: 17, signalPower: signalPower)
        let noise = ModemTestSignals.noise(seconds: 15, seed: 18)
        func time(_ audio: [Float]) -> (Double, Int) {
            let t0 = Date()
            let n = decode(audio).count
            return (Date().timeIntervalSince(t0), n)
        }
        _ = time(noise)
        let (tBusy, nBusy) = time(busy), (tNoise, _) = time(noise)
        print(String(format: "FT8 decode time: %.3f s for 8 signals at −15 dB (%d decoded), %.3f s for noise",
                     tBusy, nBusy, tNoise))
        #expect(nBusy == 8)
    }
}
