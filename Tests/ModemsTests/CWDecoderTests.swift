import Testing
import Foundation
import DSPCore
@testable import Modems

/// Keyed 700 Hz tone with leading/trailing silence and light noise.
private func morseAudio(_ text: String, wpm: Double, pitch: Double = 700, rate: Double = 48_000) -> [Float] {
    let unit = Int(MorseCode.dotSeconds(wpm: wpm) * rate)
    var keyed: [Bool] = Array(repeating: false, count: Int(0.3 * rate))
    for e in MorseCode.timeline(for: text) { keyed += Array(repeating: e.on, count: e.units * unit) }
    keyed += Array(repeating: false, count: Int(1.0 * rate))
    var seed: UInt64 = 42
    return keyed.enumerated().map { i, on in
        seed = seed &* 6364136223846793005 &+ 1
        let noise = Float(Int64(bitPattern: seed >> 11) % 1000) / 100_000
        return (on ? 0.5 * Float(sin(2 * Double.pi * pitch * Double(i) / rate)) : 0) + noise
    }
}

@Test(arguments: [15.0, 20.0, 25.0])
func decodesMorseAtSpeed(_ wpm: Double) {
    let core = CWDecoderCore()
    let audio = morseAudio("CQ TEST 73", wpm: wpm)
    var text = ""
    for start in stride(from: 0, to: audio.count, by: 4_800) {
        audio[start..<min(start + 4_800, audio.count)].withUnsafeBufferPointer { text += core.process($0) }
    }
    #expect(text.trimmingCharacters(in: .whitespaces) == "CQ TEST 73")
    #expect(abs(core.wpm - wpm) < wpm * 0.15)
}

private struct Gaussian {
    var seed: UInt64
    mutating func uniform() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return (Double(seed >> 11) + 0.5) / Double(1 << 53)
    }
    mutating func next(_ sigma: Double) -> Float {
        Float(sigma * (-2 * log(uniform())).squareRoot() * cos(2 * Double.pi * uniform()))
    }
}

private func noisyMorse(_ text: String, wpm: Double, amplitude: Double, sigma: Double, leadIn: Double) -> [Float] {
    let rate = 48_000.0
    let unit = Int(MorseCode.dotSeconds(wpm: wpm) * rate)
    var keyed = [Bool](repeating: false, count: Int((leadIn + 0.3) * rate))
    for e in MorseCode.timeline(for: text) { keyed += Array(repeating: e.on, count: e.units * unit) }
    keyed += [Bool](repeating: false, count: Int(1.0 * rate))
    var g = Gaussian(seed: 7)
    return keyed.enumerated().map { i, on in
        (on ? Float(amplitude * sin(2 * Double.pi * 700 * Double(i) / rate)) : 0) + g.next(sigma)
    }
}

private func decode(_ audio: [Float]) -> String {
    let core = CWDecoderCore()
    var text = ""
    for start in stride(from: 0, to: audio.count, by: 4_800) {
        audio[start..<min(start + 4_800, audio.count)].withUnsafeBufferPointer { text += core.process($0) }
    }
    return text
}

@Test func decodesInGaussianNoise() {
    let t = decode(noisyMorse("CQ TEST 73", wpm: 20, amplitude: 0.1, sigma: 0.02, leadIn: 0))
    #expect(t.trimmingCharacters(in: .whitespaces) == "CQ TEST 73")
}

@Test func decodesWithQuietNoiseLeadIn() {
    let t = decode(noisyMorse("CQ TEST 73", wpm: 20, amplitude: 0.1, sigma: 0.02, leadIn: 1.0))
    #expect(t.trimmingCharacters(in: .whitespaces) == "CQ TEST 73")
}

@Test func noiseOnlyProducesNoText() {
    var g = Gaussian(seed: 99)
    let audio = (0..<(5 * 48_000)).map { _ in g.next(0.05) }
    #expect(decode(audio).filter { $0 != " " }.isEmpty)
}
