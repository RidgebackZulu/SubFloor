import Testing
import Foundation
@testable import Modems

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

private let slotStart = Date(timeIntervalSince1970: 1_800_000_000)  // an even UTC minute
private let fullBand: ClosedRange<Double> = 300...3_300
private let amplitude: Float = 0.5
/// Steady power of one WSPR signal of `amplitude` (constant envelope), the SNR reference (ruling R7).
private let signalPower = Double(amplitude * amplitude) / 2

private struct Message {
    var call: String, grid: String, power: Int
    var text: String { "\(call) \(grid) \(power)" }
}

private let k1abc = Message(call: "K1ABC", grid: "FN42", power: 37)
private let g4jnt = Message(call: "G4JNT", grid: "IO90", power: 30)
private let w1aw = Message(call: "W1AW", grid: "FN31", power: 23)
private let lz0dls = Message(call: "LZ0DLS", grid: "KN12", power: 10)

/// One 120 s slot holding `message` as continuous-phase 4-FSK centred on `hz` at mid-transmission,
/// starting `start` seconds into the slot and drifting linearly by `driftHz` over the transmission.
/// With `start` = 1 and `driftHz` = 0 this is `WSPREncoder.audio` (checked in `synthMatchesEncoder`).
private func wspr(_ message: Message, hz: Double, start: Double = 1, driftHz: Double = 0,
                  amplitude: Float = amplitude, sampleRate: Double = 12_000) -> [Float] {
    let symbols = WSPRCodec.channelSymbols(call: message.call, grid: message.grid, powerDbm: message.power)!
    var out = [Float](repeating: 0, count: Int(120 * sampleRate))
    let spacing = 12_000.0 / 8_192, symbolSeconds = 8_192.0 / 12_000
    var phase = 0.0
    for (k, s) in symbols.enumerated() {
        let a = Int(((start + Double(k) * symbolSeconds) * sampleRate).rounded())
        let b = Int(((start + Double(k + 1) * symbolSeconds) * sampleRate).rounded())
        let centre = hz + driftHz * (Double(k) - 80.5) / 161
        let step = 2 * Double.pi * (centre + (Double(s) - 1.5) * spacing) / sampleRate
        for n in a..<b {
            if n >= 0 && n < out.count { out[n] = amplitude * Float(sin(phase)) }
            phase += step
            if phase > 2 * .pi { phase -= 2 * .pi }
        }
    }
    return out
}

private func sum(_ signals: [[Float]]) -> [Float] {
    var out = signals[0]
    for s in signals.dropFirst() { for i in out.indices { out[i] += s[i] } }
    return out
}

private func decode(_ audio: [Float], band: ClosedRange<Double> = fullBand, sampleRate: Double = 12_000) -> [SlotDecode] {
    WSPRModem.decode(samples: audio, sampleRate: sampleRate, slotStart: slotStart, audioBand: band)
}

/// Decode outcome of one trial: 1 = the right message (and nothing else), 0 = nothing, −1 = a wrong
/// message among the decodes.
private func outcome(_ decodes: [SlotDecode], expect message: Message) -> Int {
    if decodes.contains(where: { $0.message != message.text }) { return -1 }
    return decodes.isEmpty ? 0 : 1
}

private let messages = [k1abc, g4jnt, w1aw, lz0dls]

/// Trial `i` at `snrDb`: one message (cycling through `messages`) at a frequency spread over the
/// sub-band 1420…1580 Hz and a start of 0.5…1.5 s.
private func weakTrial(_ i: Int, snrDb: Double, seedBase: UInt64) -> Int {
    let message = messages[i % messages.count]
    let hz = 1_420 + Double((i * 37) % 160) + 0.3
    let start = 0.5 + Double((i * 7) % 10) / 10
    let audio = ModemTestSignals.awgn(wspr(message, hz: hz, start: start), snrDb: snrDb,
                                      seed: seedBase + UInt64(i), signalPower: signalPower)
    let decodes = decode(audio)
    if outcome(decodes, expect: message) == 1, let d = decodes.first, abs(d.frequencyHz - hz) > 2 { return -1 }
    return outcome(decodes, expect: message)
}

@Suite struct WSPRDecoderTests {
    @Test func catalogRegistersWSPR() {
        #expect(WSPRModem.id == .wspr)
        #expect(WSPRModem.slotSeconds == 120)
        #expect(ModemCatalog.slot(.wspr).map { ObjectIdentifier($0) } == ObjectIdentifier(WSPRModem.self))
    }

    @Test func synthMatchesEncoder() {
        let encoded = WSPREncoder.audio(call: "K1ABC", grid: "FN42", powerDbm: 37, audioHz: 1_500)!
        let synth = wspr(k1abc, hz: 1_500)
        #expect(encoded.count == synth.count)
        let worst = zip(encoded, synth).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        #expect(worst < 1e-3)
    }

    @Test func cleanDecode() throws {
        let audio = ModemTestSignals.awgn(WSPREncoder.audio(call: "K1ABC", grid: "FN42", powerDbm: 37, audioHz: 1_500)!,
                                          snrDb: 0, seed: 1, signalPower: signalPower)
        let decodes = decode(audio)
        #expect(decodes.count == 1)
        let d = try #require(decodes.first)
        #expect(d.message == "K1ABC FN42 37")
        #expect(d.mode == .wspr)
        #expect(d.slotStart == slotStart)
        #expect(abs(d.frequencyHz - 1_500) <= 2, "\(d.frequencyHz) Hz")
        #expect(abs(d.timeOffset) < 0.1, "dt \(d.timeOffset) s")
    }

    @Test func twoSignals() {
        let audio = ModemTestSignals.awgn(sum([wspr(k1abc, hz: 1_450), wspr(g4jnt, hz: 1_550)]), snrDb: -15,
                                          seed: 2, signalPower: signalPower)
        let decodes = decode(audio)
        #expect(Set(decodes.map(\.message)) == [k1abc.text, g4jnt.text])
        #expect(decodes.count == 2)
        for d in decodes {
            let expected = d.message == k1abc.text ? 1_450.0 : 1_550.0
            #expect(abs(d.frequencyHz - expected) <= 2)
        }
    }

    @Test func minus26dBGate() {
        let results = parallel(20) { weakTrial($0, snrDb: -26, seedBase: 26_000) }
        let decoded = results.filter { $0 == 1 }.count, wrong = results.filter { $0 == -1 }.count
        print("WSPR at −26 dB: \(decoded)/20 decoded, \(wrong) wrong")
        #expect(decoded >= 16)
        #expect(wrong == 0)
    }

    @Test func minus28dBStretch() {
        let results = parallel(20) { weakTrial($0, snrDb: -28, seedBase: 28_000) }
        let decoded = results.filter { $0 == 1 }.count, wrong = results.filter { $0 == -1 }.count
        print("WSPR at −28 dB (stretch, not asserted): \(decoded)/20 decoded, \(wrong) wrong")
        #expect(wrong == 0)
    }

    @Test(arguments: [0.0, 2.0])
    func timeOffsetTolerance(start: Double) throws {
        let audio = ModemTestSignals.awgn(wspr(w1aw, hz: 1_480, start: start), snrDb: -20, seed: 3,
                                          signalPower: signalPower)
        let decodes = decode(audio)
        let d = try #require(decodes.first)
        #expect(decodes.count == 1)
        #expect(d.message == w1aw.text)
        #expect(abs(d.timeOffset - (start - 1)) < 0.1, "dt \(d.timeOffset) s for start \(start) s")
    }

    @Test func noiseOnly() {
        #expect(decode(ModemTestSignals.noise(seconds: 120, seed: 4)).isEmpty)
    }

    /// Twenty independent noise slots, plus the same with steady carriers and a keyed carrier in the
    /// sub-band (which make candidates that sync and Fano must reject): no decodes at all.
    @Test func noFalseDecodesOverManyNoiseSlots() {
        let counts = parallel(20) { i -> Int in
            var audio = ModemTestSignals.noise(seconds: 120, seed: 40_000 + UInt64(i))
            if i % 2 == 1 {
                for (k, hz) in [1_420.0, 1_497.3, 1_533.0].enumerated() {
                    let carrier = ModemTestSignals.tone(hz + Double(i), seconds: 120, amplitude: 0.01 * Float(k + 1))
                    for n in audio.indices { audio[n] += carrier[n] }
                }
                // On/off keyed carrier at about a WSPR symbol rate.
                for n in audio.indices where (n / 8_192) % 3 != 0 {
                    audio[n] += 0.02 * Float(sin(2 * Double.pi * 1_570 * Double(n) / 12_000))
                }
            }
            return decode(audio).count
        }
        print("WSPR noise slots: decodes per slot \(counts)")
        #expect(counts.allSatisfy { $0 == 0 })
    }

    @Test(arguments: [1.0, -1.0])
    func driftingSignal(driftHz: Double) throws {
        let audio = ModemTestSignals.awgn(wspr(g4jnt, hz: 1_520, driftHz: driftHz), snrDb: -20, seed: 5,
                                          signalPower: signalPower)
        let decodes = decode(audio)
        let d = try #require(decodes.first)
        #expect(decodes.count == 1)
        #expect(d.message == g4jnt.text)
        #expect(abs(d.frequencyHz - 1_520) <= 1, "\(d.frequencyHz) Hz")
    }

    @Test func audioBandFiltering() {
        let audio = ModemTestSignals.awgn(sum([wspr(k1abc, hz: 1_450), wspr(g4jnt, hz: 1_550)]), snrDb: -10,
                                          seed: 6, signalPower: signalPower)
        #expect(decode(audio, band: 1_500...3_000).map(\.message) == [g4jnt.text])
        #expect(decode(audio, band: 300...1_500).map(\.message) == [k1abc.text])
        #expect(decode(audio, band: 1_460...1_540).isEmpty)
        #expect(decode(audio, band: 2_000...3_000).isEmpty)
    }

    /// Off the 200 Hz sub-band, as an up-converter a few ppm off puts signals: anywhere in the band
    /// decodes, including on the edge between two searched windows.
    @Test(arguments: [600.0, 1_411.1, 1_850.0, 2_600.0])
    func offsetSignal(hz: Double) throws {
        let audio = ModemTestSignals.awgn(wspr(g4jnt, hz: hz), snrDb: -20, seed: 14, signalPower: signalPower)
        let decodes = decode(audio, band: 300...2_800)
        let d = try #require(decodes.first)
        #expect(decodes.count == 1)
        #expect(d.message == g4jnt.text)
        #expect(abs(d.frequencyHz - hz) <= 2, "\(d.frequencyHz) Hz")
    }

    @Test func searchWindowsTileTheBand() {
        let w = WSPRDecoder.searchWindows(300...2_800)
        #expect(w.count == 9)
        #expect(abs(w.first!.centreHz - w.first!.halfWidthHz - 300) < 1e-9)
        #expect(abs(w.last!.centreHz + w.last!.halfWidthHz - 2_800) < 1e-9)
        #expect(w.allSatisfy { $0.halfWidthHz <= WSPRDecoder.searchHalfWidthHz })
        for (a, b) in zip(w, w.dropFirst()) { #expect(abs(a.centreHz + a.halfWidthHz - (b.centreHz - b.halfWidthHz)) < 1e-9) }
        #expect(WSPRDecoder.searchWindows(1_400...1_600).map(\.centreHz) == [1_500])
        #expect(WSPRDecoder.searchWindows(1_500...1_505).isEmpty)
    }

    @Test(arguments: [-20.0, -15.0, -10.0, -5.0, 0.0])
    func reportedSNR(snrDb: Double) throws {
        let audio = ModemTestSignals.awgn(wspr(lz0dls, hz: 1_510), snrDb: snrDb, seed: 7, signalPower: signalPower)
        let d = try #require(decode(audio).first)
        print("WSPR SNR \(snrDb) dB reported as \(d.snrDb) dB")
        #expect(abs(Double(d.snrDb) - snrDb) <= 2, "true \(snrDb) dB, reported \(d.snrDb) dB")
    }

    /// A strong signal with a weak one 6 Hz above it (their tone sets about one tone spacing apart):
    /// both decode, the weak one after the strong one is subtracted.
    @Test func strongAndWeakSixHzApart() {
        let strong = wspr(k1abc, hz: 1_500)
        let weak = wspr(w1aw, hz: 1_506, start: 1.2, amplitude: amplitude * Float(pow(10, -20.0 / 20)))
        let audio = ModemTestSignals.awgn(sum([strong, weak]), snrDb: 0, seed: 8, signalPower: signalPower)
        let decodes = decode(audio)
        print("WSPR strong (0 dB) + weak (−20 dB) 6 Hz apart: \(decodes.map { "\($0.message) \($0.snrDb) dB" })")
        #expect(Set(decodes.map(\.message)) == [k1abc.text, w1aw.text])
        #expect(decodes.count == 2)
    }

    @Test func shortAndOddSlotSamples() {
        #expect(decode([]).isEmpty)
        #expect(decode([Float](repeating: 0, count: 120 * 12_000)).isEmpty)
        #expect(decode(ModemTestSignals.noise(seconds: 0.5, seed: 9)).isEmpty)
        let full = ModemTestSignals.awgn(wspr(k1abc, hz: 1_500), snrDb: -15, seed: 9, signalPower: signalPower)
        // Truncated to 60 s: no crash (the message may or may not survive half its symbols).
        let half = decode(Array(full[..<(60 * 12_000)]))
        #expect(half.allSatisfy { $0.message == k1abc.text })
        // Ending just after the transmission (111.6 s), and longer than a slot: both decode.
        #expect(decode(Array(full[..<(112 * 12_000)])).map(\.message) == [k1abc.text])
        #expect(decode(full + ModemTestSignals.noise(seconds: 5, sigma: 0.01, seed: 10)).map(\.message) == [k1abc.text])
        #expect(WSPRModem.decode(samples: full, sampleRate: 0, slotStart: slotStart, audioBand: fullBand).isEmpty)
        #expect(decode(full, band: 1_500...1_500).isEmpty)
        // A corrupt sample poisons the slot's filters: no decodes, and no crash.
        var corrupt = full
        corrupt[50 * 12_000] = .nan
        #expect(decode(corrupt).allSatisfy { $0.message == k1abc.text })
    }

    @Test func otherSampleRate() {
        let rate = 48_000.0
        let audio = ModemTestSignals.awgn(wspr(g4jnt, hz: 1_470, sampleRate: rate), snrDb: -20, sampleRate: rate,
                                          seed: 11, signalPower: signalPower)
        let decodes = decode(audio, sampleRate: rate)
        #expect(decodes.map(\.message) == [g4jnt.text])
        #expect(decodes.allSatisfy { abs($0.frequencyHz - 1_470) <= 2 })
    }

    /// Decode time per slot (release build), reported for the slot queue's budget.
    @Test func decodeTime() {
        let busy = ModemTestSignals.awgn(sum([wspr(k1abc, hz: 1_420), wspr(g4jnt, hz: 1_470), wspr(w1aw, hz: 1_530),
                                              wspr(lz0dls, hz: 1_580)]),
                                         snrDb: -24, seed: 12, signalPower: signalPower)
        let noise = ModemTestSignals.noise(seconds: 120, seed: 13)
        func time(_ audio: [Float]) -> (Double, Int) {
            let t0 = Date()
            let n = decode(audio).count
            return (Date().timeIntervalSince(t0), n)
        }
        let (tBusy, nBusy) = time(busy), (tNoise, _) = time(noise)
        print(String(format: "WSPR decode time: %.2f s for 4 signals at −24 dB (%d decoded), %.2f s for noise",
                     tBusy, nBusy, tNoise))
        #expect(nBusy == 4)
    }
}
