import Testing
import Foundation
import DSPCore
@testable import Modems

/// Keyed CW at 12 kHz: `leadIn` s of silence, the text, then 1.5 s of silence. Key-down power is
/// `amplitude²/2`, which the SNR helper needs as `signalPower` (ruling R7).
private func cwAudio(_ text: String, wpm: Double, hz: Double, amplitude: Float = 0.5, leadIn: Double = 1.0,
                     rate: Double = 12_000) -> [Float] {
    let unit = Int(MorseCode.dotSeconds(wpm: wpm) * rate)
    var keyed = [Bool](repeating: false, count: Int(leadIn * rate))
    for e in MorseCode.timeline(for: text) { keyed += Array(repeating: e.on, count: e.units * unit) }
    keyed += [Bool](repeating: false, count: Int(1.5 * rate))
    return keyed.enumerated().map { i, on in
        on ? amplitude * Float(sin(2 * Double.pi * hz * Double(i) / rate)) : 0
    }
}

private func run(_ decoder: any SignalDecoder, _ audio: [Float], chunk: Int = 1_024) -> String {
    var text = ""
    for start in stride(from: 0, to: audio.count, by: chunk) {
        audio[start..<min(start + chunk, audio.count)].withUnsafeBufferPointer { text += decoder.process($0) }
    }
    return text
}

private func clean(_ s: String) -> String {
    s.split(separator: " ").joined(separator: " ")
}

@Test func decodesAtMinus8dB() {
    let sent = "CQ TEST DE W1AW K"
    let clear = cwAudio(sent, wpm: 20, hz: 800)
    let audio = ModemTestSignals.awgn(clear, snrDb: -8, seed: 1, signalPower: 0.5 * 0.5 / 2)
    let text = clean(run(CWModem.makeDecoder(frequencyHz: 800, sampleRate: 12_000), audio))
    let accuracy = ModemTestSignals.characterAccuracy(sent: sent, received: text)
    #expect(accuracy >= 0.95)
}

@Test func twoSignals150HzApartDecodeIndependently() {
    let a = cwAudio("PARIS PARIS", wpm: 18, hz: 700)
    let b = cwAudio("TEST TEST", wpm: 25, hz: 850)
    var mixed = [Float](repeating: 0, count: max(a.count, b.count))
    for i in 0..<a.count { mixed[i] += a[i] }
    for i in 0..<b.count { mixed[i] += b[i] }
    let audio = ModemTestSignals.awgn(mixed, snrDb: 10, seed: 2, signalPower: 0.5 * 0.5 / 2)
    let ta = clean(run(CWModem.makeDecoder(frequencyHz: 700, sampleRate: 12_000), audio))
    let tb = clean(run(CWModem.makeDecoder(frequencyHz: 850, sampleRate: 12_000), audio))
    #expect(ModemTestSignals.characterAccuracy(sent: "PARIS PARIS", received: ta) >= 0.95)
    #expect(ModemTestSignals.characterAccuracy(sent: "TEST TEST", received: tb) >= 0.95)
    #expect(!ta.contains("TEST"))
    #expect(!tb.contains("PARIS"))
}

@Test func noiseOnlyNoText() {
    let audio = ModemTestSignals.noise(seconds: 60, seed: 3)
    let text = run(CWModem.makeDecoder(frequencyHz: 800, sampleRate: 12_000), audio)
    #expect(text.filter { $0 != " " }.count == 0)
}

@Test func reportsSubmodeAndRegisters() {
    let decoder = CWModem.makeDecoder(frequencyHz: 800, sampleRate: 12_000)
    let audio = cwAudio("CQ TEST DE W1AW K", wpm: 25, hz: 800)
    _ = run(decoder, audio)
    #expect(decoder.submode == "CW 25WPM" || decoder.submode == "CW 24WPM" || decoder.submode == "CW 26WPM")
    #expect(decoder.constellation().isEmpty)
    #expect(ModemCatalog.streaming(.cw) != nil)
}

@Test func afcPullsTowardTrueFrequency() {
    let clear = cwAudio("CQ CQ CQ DE W1AW W1AW K CQ CQ CQ DE W1AW K", wpm: 20, hz: 806)
    let audio = ModemTestSignals.awgn(clear, snrDb: 10, seed: 4, signalPower: 0.5 * 0.5 / 2)
    let decoder = CWModem.makeDecoder(frequencyHz: 800, sampleRate: 12_000)
    let text = clean(run(decoder, audio))
    #expect(abs(decoder.frequencyHz - 806) < 2)
    #expect(ModemTestSignals.characterAccuracy(sent: "CQ CQ CQ DE W1AW W1AW K CQ CQ CQ DE W1AW K", received: text) >= 0.95)
}

@Test func resetRestoresFrequency() {
    let decoder = CWModem.makeDecoder(frequencyHz: 800, sampleRate: 12_000)
    _ = run(decoder, cwAudio("CQ CQ CQ DE W1AW K", wpm: 20, hz: 806))
    decoder.reset()
    #expect(decoder.frequencyHz == 800)
}

@Test func coreDecodesPerBlockEnvelope() {
    // Clean 5 ms magnitude blocks: noise floor 0.01 with a 0.5 tone, "CQ TEST" at 20 WPM.
    let blockMs = 5.0
    let blocksPerDot = Int((MorseCode.dotSeconds(wpm: 20) * 1_000 / blockMs).rounded())
    var env = [Float](repeating: 0.01, count: 200)
    for e in MorseCode.timeline(for: "CQ TEST") {
        env += [Float](repeating: e.on ? 0.5 : 0.01, count: e.units * blocksPerDot)
    }
    env += [Float](repeating: 0.01, count: 400)
    let core = CWDecoderCore(sampleRate: 1_000, pitchHz: 800)
    let text = env.withUnsafeBufferPointer { core.process(envelope: $0, blockMs: blockMs) }
    #expect(text.trimmingCharacters(in: .whitespaces) == "CQ TEST")
}

@Test func decodedTextDoesNotDependOnChunking() {
    let sent = "CQ TEST DE W1AW K"
    let audio = ModemTestSignals.awgn(cwAudio(sent, wpm: 20, hz: 800), snrDb: 0, seed: 7, signalPower: 0.5 * 0.5 / 2)
    let a = clean(run(CWModem.makeDecoder(frequencyHz: 800, sampleRate: 12_000), audio, chunk: 1_024))
    let b = clean(run(CWModem.makeDecoder(frequencyHz: 800, sampleRate: 12_000), audio, chunk: 333))
    #expect(a == sent)
    #expect(b == sent)
}
