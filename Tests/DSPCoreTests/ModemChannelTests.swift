import Testing
import Foundation
@testable import DSPCore

@Suite struct ModemChannelTests {
    private let inputRate = 2_000_000.0

    /// Runs `seconds` of a complex tone at `offset` Hz through the channel in 64k chunks.
    private func run(_ channel: ModemChannel, offset: Double, seconds: Double) -> [Float] {
        let iq = TestSignals.tone(frequency: offset, sampleRate: inputRate, count: Int(inputRate * seconds))
        var audio: [Float] = []
        var i = 0
        while i < iq.count {
            let n = min(65_536, iq.count - i)
            iq.withUnsafeBufferPointer { channel.process(UnsafeBufferPointer(rebasing: $0[i..<(i + n)]), audio: &audio) }
            i += n
        }
        return audio
    }

    private func tonePower(_ audio: [Float], at f: Double) -> Double {
        TestSignals.power(of: audio.dropFirst(1_000), at: f, sampleRate: ModemChannel.outputRate)
    }

    @Test func upperSidebandToneAppearsAtAudioFrequency() {
        let channel = ModemChannel(inputRate: inputRate, dialOffsetHz: 50_000)
        let audio = run(channel, offset: 51_000, seconds: 0.5)
        #expect(TestSignals.dominates(audio.dropFirst(1_000), at: 1_000, sampleRate: 12_000, over: [500, 1_500, 2_000]))
    }

    @Test func lowerSidebandIsRejected() {
        let usb = run(ModemChannel(inputRate: inputRate, dialOffsetHz: 50_000), offset: 51_000, seconds: 0.5)
        let lsb = run(ModemChannel(inputRate: inputRate, dialOffsetHz: 50_000), offset: 49_000, seconds: 0.5)
        let ratioDb = 10 * log10(tonePower(usb, at: 1_000) / max(tonePower(lsb, at: 1_000), 1e-30))
        #expect(ratioDb >= 40)
    }

    @Test func outputRateIsExactly12k() {
        let channel = ModemChannel(inputRate: inputRate, dialOffsetHz: 50_000)
        let audio = run(channel, offset: 51_000, seconds: 2)
        #expect(abs(audio.count - 24_000) <= 12)
    }

    @Test func passbandCovers300To3300() {
        func level(_ f: Double) -> Double {
            let audio = run(ModemChannel(inputRate: inputRate, dialOffsetHz: 50_000), offset: 50_000 + f, seconds: 0.5)
            return tonePower(audio, at: f)
        }
        let reference = level(1_500)
        for f in [300.0, 3_300.0] {
            let db = 10 * log10(level(f) / reference)
            #expect(abs(db) <= 1, "tone at \(f) Hz is \(db) dB from reference")
        }
    }

    @Test func fractionalResamplerPreservesTone() {
        var resampler = FractionalResampler(inputRate: 31_250, outputRate: 12_000)
        let n = 31_250
        let input: [Float] = (0..<n).map { Float(sin(2 * Double.pi * 1_000 * Double($0) / 31_250)) }
        var out: [Float] = []
        input.withUnsafeBufferPointer { resampler.process($0, into: &out) }
        let ideal = Double(n) * 12_000 / 31_250
        #expect(abs(Double(out.count) - ideal) <= 2)
        #expect(TestSignals.dominates(out.dropFirst(100), at: 1_000, sampleRate: 12_000, over: [500, 1_500, 2_500, 4_000]))
    }

    @Test func retuneDoesNotRebuild() {
        let channel = ModemChannel(inputRate: inputRate, dialOffsetHz: 50_000)
        let seconds = 1.0
        let iq = TestSignals.tone(frequency: 51_000, sampleRate: inputRate, count: Int(inputRate * seconds))
        let half = iq.count / 2
        var first: [Float] = []
        var second: [Float] = []
        iq.withUnsafeBufferPointer {
            channel.process(UnsafeBufferPointer(rebasing: $0[0..<half]), audio: &first)
            channel.setDialOffset(49_500)
            channel.process(UnsafeBufferPointer(rebasing: $0[half...]), audio: &second)
        }
        #expect(abs(first.count + second.count - 12_000) <= 6)
        #expect(TestSignals.dominates(first.dropFirst(1_000), at: 1_000, sampleRate: 12_000, over: [1_500]))
        #expect(TestSignals.dominates(second.dropFirst(1_000), at: 1_500, sampleRate: 12_000, over: [1_000]))
    }
}
