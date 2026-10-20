import Testing
import Foundation
import Accelerate
@testable import DSPCore

@Test func amRecoversModulatingTone() {
    let fs = 48_000.0
    let iq = TestSignals.modulated(sampleRate: fs, seconds: 0.5) { t in (0.5 * (1 + 0.5 * cos(2 * .pi * 1000 * t)), 0) }
    var out = [Float]()
    iq.withUnsafeBufferPointer { AMDemodulator().demodulate($0, into: &out) }
    #expect(TestSignals.dominates(out[4800...], at: 1000, sampleRate: fs, over: [500, 1500, 2000]))
}

@Test func fmRecoversModulatingToneWithUnitScale() {
    let fs = 48_000.0, dev = 3_000.0, fm = 1_000.0
    let iq = TestSignals.modulated(sampleRate: fs, seconds: 0.5) { t in (1, dev / fm * sin(2 * .pi * fm * t)) }
    var out = [Float]()
    iq.withUnsafeBufferPointer { FMDemodulator(sampleRate: fs, deviation: 5_000, deemphasisTau: nil).demodulate($0, into: &out) }
    #expect(TestSignals.dominates(out[4800...], at: fm, sampleRate: fs, over: [500, 2000, 3000]))
    let peak = out[4800...].map { abs($0) }.max()!
    #expect(abs(peak - 0.6) < 0.05)   // 3 kHz deviation / 5 kHz full scale
}

@Test func ssbShiftsBasebandToneToAudio() {
    let fs = 24_000.0
    let iq = TestSignals.tone(frequency: -450, sampleRate: fs, count: 24_000)
    var out = [Float]()
    iq.withUnsafeBufferPointer { SSBDemodulator(sampleRate: fs, shiftHz: 1450).demodulate($0, into: &out) }
    #expect(TestSignals.dominates(out[2400...], at: 1000, sampleRate: fs, over: [450, 1450, 1900]))
}

@Test func resamplerProducesExpectedCountAndKeepsTone() {
    var r = LinearResampler(inputRate: 31_250, outputRate: 48_000)
    let x = (0..<31_250).map { Float(sin(2 * Double.pi * 440 * Double($0) / 31_250)) }
    var out = [Float]()
    for chunk in stride(from: 0, to: x.count, by: 1000) {
        x[chunk..<min(chunk + 1000, x.count)].withUnsafeBufferPointer { r.process($0, into: &out) }
    }
    #expect(abs(out.count - 48_000) <= 2)
    #expect(TestSignals.dominates(out[1000...], at: 440, sampleRate: 48_000, over: [220, 880, 1500]))
}

@Test func agcBringsQuietSignalToTarget() {
    var agc = AGC(speed: .fast, sampleRate: 48_000)
    var x = (0..<48_000).map { Float(0.001 * sin(2 * Double.pi * 700 * Double($0) / 48_000)) }
    agc.process(&x, from: 0)
    let peak = x[24_000...].map { abs($0) }.max()!
    #expect(peak > 0.15 && peak < 0.4)
}

@Test func ssbPassbandOffsets() {
    #expect(DemodMode.usb.passbandOffset(bandwidth: 2_700) == 1_450)
    #expect(DemodMode.lsb.passbandOffset(bandwidth: 2_700) == -1_450)
    #expect(DemodMode.cw.passbandOffset(bandwidth: 500) == 0)
}
