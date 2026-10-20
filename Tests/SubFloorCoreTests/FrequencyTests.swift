import Testing
@testable import SubFloorCore

@Test(arguments: [
    ("14.074", 14_074_000.0), ("7074k", 7_074_000), ("7074", 7_074_000), ("144.39m", 144_390_000),
    ("144390", 144_390_000), ("125000000", 125_000_000), ("1.2g", 1_200_000_000), ("14.074.000", 14_074_000),
    ("7.074 MHz", 7_074_000), ("7074kHz", 7_074_000), ("10,000,000", 10_000_000), (" 14 ", 14_000_000),
    ("500hz", 500), ("14074 Hz", 14_074), ("1500000Hz", 1_500_000),
])
func parsesFrequency(_ input: String, _ expected: Double) {
    #expect(FrequencyParser.parse(input) == expected)
}

@Test(arguments: ["", "m", "abc", "-5", "0", "1.2.3k"])
func rejectsInvalidFrequency(_ input: String) {
    #expect(FrequencyParser.parse(input) == nil)
}

@Test func formatsFrequencies() {
    #expect(FrequencyFormatter.grouped(14_074_000) == "14.074.000")
    #expect(FrequencyFormatter.grouped(1_200_000_000) == "1.200.000.000")
    #expect(FrequencyFormatter.grouped(999) == "999")
    #expect(FrequencyFormatter.readoutDigits(14_074_000) == [0, 0, 1, 4, 0, 7, 4, 0, 0, 0])
    #expect(FrequencyFormatter.short(14_074_000) == "14.074 MHz")
    #expect(FrequencyFormatter.short(1_200_000_000) == "1.2 GHz")
    #expect(FrequencyFormatter.short(500_000) == "500 kHz")
    #expect(FrequencyFormatter.short(700) == "700 Hz")
    #expect(FrequencyFormatter.rate(2_000_000) == "2.000 MSPS")
    #expect(FrequencyFormatter.rate(500_000) == "500.0 kSPS")
}

@Test func formatsAudioFrequencies() {
    #expect(FrequencyFormatter.audio(1_520) == "1,520 Hz")
    #expect(FrequencyFormatter.audio(720) == "720 Hz")
    #expect(FrequencyFormatter.audio(1_519.6) == "1,520 Hz")
    #expect(FrequencyFormatter.audio(3_300) == "3,300 Hz")
    #expect(FrequencyFormatter.audio(.nan) == "0 Hz")
}

@Test func upconverterMapsDisplayAndHardware() {
    let up = Upconverter(enabled: true)
    #expect(up.hardware(fromDisplay: 7_100_000) == 132_100_000)
    #expect(up.display(fromHardware: 132_100_000) == 7_100_000)
    let off = Upconverter(enabled: false)
    #expect(off.hardware(fromDisplay: 7_100_000) == 7_100_000)
}

@Test func tuningPlannerRetunesOnlyOutsideUsableSpan() {
    let fs = 2_000_000.0
    #expect(TuningPlanner.center(forVFO: 14_074_000, sampleRate: fs) == 13_974_000)
    #expect(TuningPlanner.retuneIfNeeded(vfo: 14_500_000, center: 14_100_000, sampleRate: fs) == nil)
    #expect(TuningPlanner.retuneIfNeeded(vfo: 15_100_000, center: 14_100_000, sampleRate: fs) == 15_000_000)
}

@Test func rsp1bLimits() {
    #expect(RSP1B.lnaStateCount(forHz: 14_000_000) == 7)
    #expect(RSP1B.lnaStateCount(forHz: 144_000_000) == 10)
    #expect(RSP1B.lnaStateCount(forHz: 1_296_000_000) == 9)
    #expect(RSP1B.ifBandwidthKHz(sampleRate: 2_000_000, decimation: 1) == 1536)
    #expect(RSP1B.ifBandwidthKHz(sampleRate: 8_000_000, decimation: 1) == 8000)
    #expect(RSP1B.ifBandwidthKHz(sampleRate: 2_000_000, decimation: 4) == 300)
    #expect(RSP1B.clampHardware(3_000_000_000) == 2_000_000_000)
    #expect(RSP1B.clampHardware(10) == 1_000)
}

@Test func hugeAndNonFiniteFrequenciesDoNotCrash() {
    #expect(FrequencyParser.parse("99999999999g") == nil)
    #expect(FrequencyParser.parse(String(repeating: "9", count: 25)) == nil)
    #expect(FrequencyParser.parse("1.2g") == 1_200_000_000)
    _ = FrequencyFormatter.grouped(1e30)
    #expect(FrequencyFormatter.grouped(.nan) == "0")
    #expect(FrequencyFormatter.readoutDigits(.infinity) == [Int](repeating: 0, count: 10))
}
