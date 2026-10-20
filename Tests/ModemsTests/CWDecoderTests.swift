import Testing
import Foundation
import SwiftUI
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

@Test func registryFindsCWModem() {
    #expect(ModemRegistry.type(withID: "cw") != nil)
    #expect(ModemRegistry.infos.map(\.id).contains("cw"))
    #expect(CWDecoderModem.info.preferredMode == .cw)
}

@Test func hostForwardsAudioToActiveModem() {
    let host = ModemHost()
    let probe = ProbeModem()
    host.set(probe)
    let context = ModemContext(sampleRate: 48_000, mode: .cw, bandwidthHz: 500, cwPitchHz: 700)
    [Float](repeating: 0, count: 128).withUnsafeBufferPointer { host.process(audio: $0, context: context) }
    #expect(probe.received == 128)
    host.set(nil)
    [Float](repeating: 0, count: 128).withUnsafeBufferPointer { host.process(audio: $0, context: context) }
    #expect(probe.received == 128)
}

private final class ProbeModem: Modem, @unchecked Sendable {
    static let info = ModemInfo(id: "probe", name: "Probe", input: .audio, preferredMode: nil, preferredBandwidth: nil)
    var received = 0
    init() {}
    func reset() {}
    func process(audio: UnsafeBufferPointer<Float>, context: ModemContext) { received += audio.count }
    @MainActor func makeOutputView() -> AnyView { AnyView(EmptyView()) }
}
