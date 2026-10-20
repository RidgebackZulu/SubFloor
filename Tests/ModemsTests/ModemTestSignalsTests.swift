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
