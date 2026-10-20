import Testing
import Foundation
import Accelerate
@testable import DSPCore

private let fs = 2_000_000.0

private func run(_ config: Receiver.Config, _ iq: [DSPComplex]) -> [Float] {
    let rx = Receiver(config: config)
    var audio = [Float]()
    var i = 0
    while i < iq.count {     // realistic 10 ms blocks
        let end = min(iq.count, i + 20_000)
        iq[i..<end].withUnsafeBufferPointer { rx.process($0, audio: &audio) }
        i = end
    }
    return audio
}

private func config(_ mode: DemodMode, offset: Double = 50_000) -> Receiver.Config {
    Receiver.Config(inputRate: fs, offsetHz: offset, mode: mode, bandwidthHz: mode.defaultBandwidth)
}

@Test func outputRateIs48k() {
    let audio = run(config(.am), [DSPComplex](repeating: DSPComplex(real: 0.1, imag: 0), count: Int(fs)))
    #expect(abs(audio.count - 48_000) < 300)
}

@Test func amChannel() {
    let iq = TestSignals.modulated(sampleRate: fs, seconds: 0.5) { t in
        (0.5 * (1 + 0.5 * cos(2 * .pi * 1_000 * t)), 2 * .pi * 50_000 * t)
    }
    let audio = run(config(.am), iq)
    #expect(TestSignals.dominates(audio[4_800...], at: 1_000, sampleRate: 48_000, over: [500, 1_500, 2_000, 3_000]))
}

@Test func nfmChannel() {
    let iq = TestSignals.modulated(sampleRate: fs, seconds: 0.5) { t in
        let carrier: Double = 2 * .pi * 50_000 * t
        let mod: Double = 3_000.0 / 1_000.0 * sin(2 * .pi * 1_000 * t)
        return (0.5, carrier + mod)
    }
    let audio = run(config(.nfm), iq)
    #expect(TestSignals.dominates(audio[4_800...], at: 1_000, sampleRate: 48_000, over: [500, 2_000, 3_000]))
}

@Test func wfmChannel() {
    let iq = TestSignals.modulated(sampleRate: fs, seconds: 0.5) { t in
        let carrier: Double = 2 * .pi * 200_000 * t
        let mod: Double = 50_000.0 / 1_000.0 * sin(2 * .pi * 1_000 * t)
        return (0.5, carrier + mod)
    }
    let audio = run(config(.wfm, offset: 200_000), iq)
    #expect(TestSignals.dominates(audio[4_800...], at: 1_000, sampleRate: 48_000, over: [500, 2_000, 3_000]))
}

@Test func usbChannel() {
    let iq = TestSignals.tone(frequency: 51_000, sampleRate: fs, count: Int(fs / 2), amplitude: 0.1)
    let audio = run(config(.usb), iq)
    #expect(TestSignals.dominates(audio[4_800...], at: 1_000, sampleRate: 48_000, over: [450, 1_450, 2_000]))
}

@Test func lsbChannelRejectsUpperSideband() {
    let lower = run(config(.lsb), TestSignals.tone(frequency: 49_000, sampleRate: fs, count: Int(fs / 2), amplitude: 0.1))
    #expect(TestSignals.dominates(lower[4_800...], at: 1_000, sampleRate: 48_000, over: [450, 1_450, 2_000]))
    // A tone on the wrong sideband must be far weaker than the right one (AGC disabled to compare levels).
    var c = config(.lsb); c.agc = .off
    let right = run(c, TestSignals.tone(frequency: 49_000, sampleRate: fs, count: Int(fs / 2), amplitude: 0.1))
    let wrong = run(c, TestSignals.tone(frequency: 51_000, sampleRate: fs, count: Int(fs / 2), amplitude: 0.1))
    let pr = TestSignals.power(of: right[4_800...], at: 1_000, sampleRate: 48_000)
    let pw = TestSignals.power(of: wrong[4_800...], at: 1_000, sampleRate: 48_000)
    #expect(pw * 1_000 < pr)
}

@Test func cwCarrierBecomesPitchTone() {
    let iq = TestSignals.tone(frequency: 50_000, sampleRate: fs, count: Int(fs / 2), amplitude: 0.1)
    let audio = run(config(.cw), iq)
    #expect(TestSignals.dominates(audio[4_800...], at: 700, sampleRate: 48_000, over: [350, 1_000, 1_400]))
}

@Test func squelchMutesSilence() {
    var c = config(.nfm); c.squelchDb = -60
    let audio = run(c, [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: 200_000))
    #expect(!audio.isEmpty && audio.allSatisfy { $0 == 0 })
}

@Test func retuningOffsetDoesNotRebuildChain() {
    let rx = Receiver(config: config(.usb))
    let rate = rx.channelRate
    var c = rx.config; c.offsetHz = 10_000
    rx.update(c)
    #expect(rx.channelRate == rate && rx.config.offsetHz == 10_000)
}

@Test func agcEnvelopeSurvivesReceiverRebuild() {
    let rx = Receiver(config: config(.usb))
    let iq = TestSignals.tone(frequency: 51_000, sampleRate: fs, count: Int(fs / 2), amplitude: 0.1)
    var audio = [Float]()
    var i = 0
    func feed(_ end: Int) {
        while i < end {
            let e = min(end, i + 20_000)
            iq[i..<e].withUnsafeBufferPointer { rx.process($0, audio: &audio) }
            i = e
        }
    }
    feed(iq.count - 200_000)
    let steadyPeak = audio.suffix(2_400).map(abs).max() ?? 0
    #expect(steadyPeak > 0.05)
    audio.removeAll()
    var changed = config(.usb)
    changed.bandwidthHz = 2_400
    rx.update(changed)
    feed(iq.count)
    // Filter group delay swallows the first few ms, so look at the first 100 ms (which includes the first 10 ms).
    let firstTen = audio.prefix(480).map(abs).max() ?? 0
    let firstHundred = audio.prefix(4_800).map(abs).max() ?? 0
    #expect(firstTen <= 2 * steadyPeak)
    #expect(firstHundred <= 2 * steadyPeak)
}
