import Testing
import Foundation
import CSDRplay
import DSPCore
@testable import SDRplayKit

@Test func agcMapsToApiValues() {
    #expect(HardwareAGC.off.api == sdrplay_api_AGC_DISABLE)
    #expect(HardwareAGC.hz5.api == sdrplay_api_AGC_5HZ)
    #expect(HardwareAGC.hz50.api == sdrplay_api_AGC_50HZ)
    #expect(HardwareAGC.hz100.api == sdrplay_api_AGC_100HZ)
}

@Test func settingsOutputRateAccountsForDecimation() {
    var s = SDRplaySettings()
    s.sampleRate = 8_000_000
    s.decimation = 4
    #expect(s.outputRate == 2_000_000)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SUBFLOOR_HW"] == "1"))
func streamsFromRealRSP() async throws {
    let device = try SDRplayDevice.open()
    defer { device.close() }
    let counter = SampleCounter()
    try device.setCenterFrequency(100_000_000)
    try device.start { counter.add($0.count) }
    try await Task.sleep(for: .milliseconds(700))
    device.stop()
    #expect(counter.value > 500_000)
}

private final class SampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add(_ n: Int) { lock.withLock { total += n } }
    var value: Int { lock.withLock { total } }
}
