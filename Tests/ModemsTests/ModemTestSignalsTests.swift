import Testing
import Foundation
@testable import Modems

@Test func awgnHitsRequestedSNR() {
    let fs = 12_000.0
    let tone = ModemTestSignals.tone(1_000, seconds: 20, amplitude: 0.5, sampleRate: fs)
    let noisy = ModemTestSignals.awgn(tone, snrDb: -10, sampleRate: fs, seed: 7)
    #expect(noisy.count == tone.count)

    let pSignal = tone.reduce(0.0) { $0 + Double($1 * $1) } / Double(tone.count)
    var pNoise = 0.0
    for i in 0..<tone.count {
        let n = Double(noisy[i] - tone[i])
        pNoise += n * n
    }
    pNoise /= Double(tone.count)
    // Noise power falling inside a 2.5 kHz bandwidth of a fs/2 wide spectrum.
    let measured = 10 * log10(pSignal / (pNoise * 2_500 / (fs / 2)))
    #expect(abs(measured - -10) < 0.3)
}

@Test func awgnIsDeterministicPerSeed() {
    let x = ModemTestSignals.tone(700, seconds: 0.5)
    #expect(ModemTestSignals.awgn(x, snrDb: 0, seed: 1) == ModemTestSignals.awgn(x, snrDb: 0, seed: 1))
    #expect(ModemTestSignals.awgn(x, snrDb: 0, seed: 1) != ModemTestSignals.awgn(x, snrDb: 0, seed: 2))
}

@Test func accuracyMetric() {
    #expect(ModemTestSignals.characterAccuracy(sent: "HELLO", received: "HELLO") == 1.0)
    #expect(abs(ModemTestSignals.characterAccuracy(sent: "HELLO", received: "HELO") - 0.8) < 1e-12)
    #expect(ModemTestSignals.characterAccuracy(sent: "HELLO", received: "") == 0)
    // Heavy garbage clamps at zero rather than going negative.
    #expect(ModemTestSignals.characterAccuracy(sent: "AB", received: "XXXXXXXX") == 0)
}

@Test func modeTable() {
    #expect(ModeID.allCases == [.cw, .psk31, .rtty, .ft8, .wspr])
    #expect(ModeID.allCases.map(\.label) == ["CW", "PSK31", "RTTY", "FT8", "WSPR"])
    #expect(ModeID.allCases.map(\.listenWidthHz) == [250, 150, 400, 100, 50])
    #expect(ModeID.allCases.map(\.lockRangeHz) == [25, 15, 30, 10, 5])
    #expect(ModeID.allCases.map(\.isSlotMode) == [false, false, false, true, true])
    #expect(ModeID.cw.id == "cw")
}

@Test func catalogStartsEmptyAndLooksUpByID() {
    #expect(ModemCatalog.streaming(.cw) == nil || ModemCatalog.streaming.contains { $0.id == .cw })
    #expect(ModemCatalog.slot(.ft8) == nil || ModemCatalog.slot.contains { $0.id == .ft8 })
}

@Test func settingsDefaults() {
    let s = ModemSettings()
    #expect(s.mode == nil)
    #expect(!s.autoDetect)
    #expect(!s.audioWide)
    #expect(s.slotModesEnabled)
}

@Test func noiseIsPureGaussianWithRequestedSigma() {
    let fs = 12_000.0
    let n = ModemTestSignals.noise(seconds: 10, sigma: 0.05, seed: 3, sampleRate: fs)
    #expect(n.count == 120_000)
    let mean = n.reduce(0.0) { $0 + Double($1) } / Double(n.count)
    let variance = n.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(n.count)
    #expect(abs(mean) < 0.001)
    #expect(abs(variance.squareRoot() - 0.05) / 0.05 < 0.01)
    // Roughly Gaussian: about 4.55% of samples beyond 2σ.
    let beyond2Sigma = Double(n.filter { abs($0) > 0.1 }.count) / Double(n.count)
    #expect(abs(beyond2Sigma - 0.0455) < 0.003)
    // Default sigma, determinism and seed sensitivity.
    #expect(ModemTestSignals.noise(seconds: 0.5, seed: 9) == ModemTestSignals.noise(seconds: 0.5, sigma: 0.05, seed: 9))
    #expect(ModemTestSignals.noise(seconds: 0.5, seed: 9) != ModemTestSignals.noise(seconds: 0.5, seed: 10))
}

@Test func awgnOnSilenceWithoutSignalPowerIsSilent() {
    // Documents the pitfall ruling R7 closes: the mean square of zeros is zero, so no noise is added.
    let silent = ModemTestSignals.awgn([Float](repeating: 0, count: 1_000), snrDb: 0, seed: 1)
    #expect(silent.allSatisfy { $0 == 0 })
}

@Test func awgnSignalPowerOverridesBufferMeanSquare() {
    let fs = 12_000.0
    let amplitude: Float = 0.5
    // 2 s tone followed by 8 s of silence: the buffer mean square is a fifth of the in-burst power.
    let burst = ModemTestSignals.tone(1_000, seconds: 2, amplitude: amplitude, sampleRate: fs)
    let padded = burst + [Float](repeating: 0, count: Int(8 * fs))
    let inBurstPower = Double(amplitude * amplitude) / 2
    let noisy = ModemTestSignals.awgn(padded, snrDb: -10, sampleRate: fs, seed: 5, signalPower: inBurstPower)

    var pNoise = 0.0
    for i in 0..<padded.count {
        let n = Double(noisy[i] - padded[i])
        pNoise += n * n
    }
    pNoise /= Double(padded.count)
    let measured = 10 * log10(inBurstPower / (pNoise * 2_500 / (fs / 2)))
    #expect(abs(measured - -10) < 0.3)

    // Without the override the noise would be scaled to the diluted mean square, 10·log10(5) ≈ 7 dB lower.
    let diluted = ModemTestSignals.awgn(padded, snrDb: -10, sampleRate: fs, seed: 5)
    var pDiluted = 0.0
    for i in 0..<padded.count {
        let n = Double(diluted[i] - padded[i])
        pDiluted += n * n
    }
    pDiluted /= Double(padded.count)
    #expect(abs(10 * log10(pNoise / pDiluted) - 10 * log10(5)) < 0.3)
}
