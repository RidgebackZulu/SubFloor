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

        // Phase continuity: the retune seam must not show a step bigger than the steady-state signal does.
        let combined = first + second
        let seam = first.count
        func maxStep(_ range: Range<Int>) -> Float {
            range.map { abs(combined[$0 + 1] - combined[$0]) }.max() ?? 0
        }
        let steady = max(maxStep(1_000..<(seam - 100)), maxStep((seam + 100)..<(combined.count - 1)))
        let atSeam = maxStep((seam - 20)..<(seam + 20))
        #expect(steady > 0.4)
        #expect(atSeam <= 1.5 * steady, "seam step \(atSeam) vs steady \(steady)")
    }

    @Test func resamplerChunkInvariance() {
        let n = 20_003   // not a multiple of 31250/12000 steps: avoids an exact-boundary output whose inclusion is rounding-dependent
        let input: [Float] = (0..<n).map { i in
            let t = Double(i) / 31_250
            return Float(sin(2 * Double.pi * 1_000 * t) + 0.5 * sin(2 * Double.pi * 3_700 * t + 1) + 0.1 * sin(2 * Double.pi * 11_000 * t))
        }
        var whole = FractionalResampler(inputRate: 31_250, outputRate: 12_000)
        var reference: [Float] = []
        input.withUnsafeBufferPointer { whole.process($0, into: &reference) }

        var chunked = FractionalResampler(inputRate: 31_250, outputRate: 12_000)
        var result: [Float] = []
        let sizes = [1, 7, 333, 1_000]
        var i = 0, k = 0
        while i < n {
            let m = min(sizes[k % sizes.count], n - i)
            input.withUnsafeBufferPointer { chunked.process(UnsafeBufferPointer(rebasing: $0[i..<(i + m)]), into: &result) }
            i += m
            k += 1
        }
        #expect(result.count == reference.count)
        let diff = zip(result, reference).map { abs($0 - $1) }.max() ?? 0
        #expect(diff < 1e-6, "max chunking difference \(diff)")
    }

    @Test func unityGain() {
        let audio = run(ModemChannel(inputRate: inputRate, dialOffsetHz: 50_000), offset: 51_500, seconds: 0.5)
        let body = audio.dropFirst(1_000)
        let rms = (body.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(body.count)).squareRoot()
        let amplitude = rms * 2.0.squareRoot()
        #expect(abs(amplitude - 1.0) <= 0.05, "amplitude \(amplitude)")
    }
}
