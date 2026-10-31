import AppKit
import DSPCore
import Foundation
import SDRplayKit
import SubFloorCore
import Synchronization
import Testing
@testable import SubFloor

/// A stand-in for `SDRplayDevice.open`: counts calls, and either fails at once or blocks until
/// released (a stuck SDRplay service), then fails.
final class FakeRSPOpener: Sendable {
    let calls = Mutex(0)
    private let blocks: Bool
    private let gate = DispatchSemaphore(value: 0)

    init(blocks: Bool = false) { self.blocks = blocks }

    var callCount: Int { calls.withLock { $0 } }
    /// Lets every blocked open return (with an error).
    func release() { for _ in 0..<8 { gate.signal() } }

    func open() throws -> SDRplayDevice {
        calls.withLock { $0 += 1 }
        if blocks { gate.wait() }
        throw SDRplayError.noDevice
    }
}

@MainActor
struct AppModelTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Never opens the real RSP: a unit test that did could hang on a stuck SDRplay service.
    private func makeModel(dir: URL? = nil, opener: FakeRSPOpener = FakeRSPOpener(),
                           timeout: Duration = .seconds(10)) -> AppModel {
        let dir = dir ?? tempDir()
        return AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                        defaults: UserDefaults(suiteName: UUID().uuidString)!,
                        openRSP: { try opener.open() }, rspOpenTimeout: timeout)
    }

    /// Waits (letting the main actor run) until `condition` holds or `seconds` pass. In the full
    /// suite other tests can hold the main thread for seconds; past the deadline it yields once
    /// more, so main-actor work that came due meanwhile (the open's timeout) runs before the last check.
    private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline {
                await Task.yield()
                return condition()
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test func shutdownOnUnstartedModelIsSafeAndIdempotent() {
        let m = makeModel()
        m.shutdown()
        m.shutdown()
        #expect(!m.isRunning)
    }

    @Test func failedRSPOpenFallsBackToDemoWithoutRetrying() async {
        let opener = FakeRSPOpener()
        let m = makeModel(opener: opener)
        defer { m.shutdown() }
        m.start()
        #expect(await eventually { m.isRunning })
        #expect(m.sourceKind == .synthetic)
        #expect(m.rspOpenFailed)
        #expect(m.banner?.action == .retry)
        #expect(m.rspConnection == .idle)
        m.banner = nil
        m.start()   // e.g. a sample-rate change: must not retry or re-show the banner
        #expect(m.banner == nil)
        #expect(opener.callCount == 1)
        m.useSource(.sdrplay)   // explicit request clears the flag and tries again
        #expect(await eventually { m.banner != nil })
        #expect(opener.callCount == 2)
    }

    /// A stuck SDRplay service blocks the open for ever: the radio waits (stopped, "Connecting")
    /// until the timeout, then runs the demo signal with the restart banner, and opens nothing more.
    @Test func stalledRSPOpenFallsBackToDemoWithTheRestartBanner() async {
        let opener = FakeRSPOpener(blocks: true)
        let m = makeModel(opener: opener, timeout: .milliseconds(200))
        defer {
            m.shutdown()
            opener.release()
        }
        m.start()
        #expect(!m.isRunning)
        #expect(m.rspConnection == .opening)
        #expect(await eventually { m.isRunning })
        #expect(m.sourceKind == .synthetic)
        #expect(m.rspConnection == .stalled)
        #expect(m.banner?.action == .copyServiceRestart)
        #expect(m.banner?.message == AppModel.serviceStalledMessage)
        m.banner = nil
        m.start()
        m.useSource(.sdrplay)   // the API is stuck in this process: no second open
        #expect(m.banner?.action == .copyServiceRestart)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(opener.callCount == 1)
        #expect(m.isRunning && m.sourceKind == .synthetic)
        // The stuck open finally failing changes nothing the user sees.
        opener.release()
        #expect(await eventually { m.rspConnection == .idle })
        #expect(m.isRunning && m.sourceKind == .synthetic)
        #expect(m.banner?.action == .copyServiceRestart)
    }

    @Test func choosingDemoWhileTheRSPOpensRunsTheDemoAndIgnoresTheOpen() async {
        let opener = FakeRSPOpener(blocks: true)
        let m = makeModel(opener: opener)
        defer { m.shutdown() }
        m.start()
        #expect(m.rspConnection == .opening)
        m.useSource(.synthetic)
        #expect(m.isRunning && m.sourceKind == .synthetic)
        opener.release()
        #expect(await eventually { m.rspConnection == .idle })
        #expect(m.isRunning && m.sourceKind == .synthetic)
        #expect(m.banner == nil)
    }

    @Test func copyingTheRestartCommandPutsItOnThePasteboard() {
        let m = makeModel()
        defer { m.shutdown() }
        m.perform(.copyServiceRestart)
        #expect(NSPasteboard.general.string(forType: .string) == AppModel.serviceRestartCommand)
        #expect(m.banner?.kind == .info)
    }

    @Test func switchingToDemoLeavesNoDeviceOpen() {
        let m = makeModel()
        m.useSource(.synthetic)
        defer { m.shutdown() }
        #expect(m.sourceKind == .synthetic)
        #expect(m.preferredSource == .synthetic)
    }

    @Test func overloadFlagTracksEvents() {
        let m = makeModel()
        m.handleOverload(true)
        #expect(m.overloaded)
        #expect(m.banner?.action == .reduceGain)
        m.handleOverload(false)
        #expect(!m.overloaded)
        #expect(m.banner == nil)
    }

    @Test func consecutiveDigitStepsAccumulate() {
        let m = makeModel()
        let start = m.vfoHz
        m.stepDigit(power: 3, ticks: 1)
        m.stepDigit(power: 3, ticks: 1)
        #expect(m.vfoHz == start + 2_000)
    }

    @Test func setVFOInsideUsableSpanKeepsCenter() {
        let m = makeModel()
        let center = m.centerHz
        m.setVFO(center + 400_000)
        #expect(m.centerHz == center)
        #expect(m.vfoHz == center + 400_000)
    }

    @Test func setVFOOutsideUsableSpanRetunesPerPlanner() {
        let m = makeModel()
        let target = 18_000_000.0
        let expected = TuningPlanner.center(forVFO: target, sampleRate: m.sampleRate)
        m.setVFO(target)
        #expect(m.centerHz == expected)
        #expect(m.vfoHz == target)
    }

    @Test func zoomAndPanNeverChangeCenter() {
        let m = makeModel()
        let center = m.centerHz
        let vfo = m.vfoHz
        let span = m.viewport.spanHz
        m.zoom(by: 0.25, anchor: 0.5)
        #expect(m.viewport.spanHz < span)
        m.pan(byFraction: 0.2)
        m.pan(byFraction: -0.5)
        m.zoom(by: 2, anchor: 0.1)
        #expect(m.centerHz == center)
        #expect(m.vfoHz == vfo)
    }

    @Test func selectBookmarkAppliesModeBandwidthUpconverterAndTunes() {
        let m = makeModel()
        let b = BookmarkStore.defaults.first { $0.upconverter }!
        m.select(b)
        #expect(m.mode == b.mode)
        #expect(m.bandwidthHz == b.bandwidthHz)
        #expect(m.upconverter.enabled)
        #expect(m.vfoHz == b.frequencyHz)
        #expect(m.centerHz == TuningPlanner.center(forVFO: b.frequencyHz, sampleRate: m.sampleRate))
    }

    @Test func setUpconverterKeepsDisplayVFO() {
        let m = makeModel()
        let vfo = m.vfoHz
        m.setUpconverter(true)
        #expect(m.upconverter.enabled)
        #expect(m.vfoHz == vfo)
        m.setUpconverter(false)
        #expect(m.vfoHz == vfo)
    }

    /// A HamItUp toggle at the same display centre retunes the hardware but leaves the IQ file's context
    /// alone: the IQ heard before it must not reach a snapshot (or a pre-roll) of what comes after.
    @Test func upconverterToggleIsABarrierInTheIQHistory() async {
        let m = makeModel()
        defer { m.shutdown() }
        m.recording.preRollSeconds = 5
        m.useSource(.synthetic)
        guard m.isRunning else {
            print("engine did not start (tolerated, no audio device)")
            return
        }
        let r = m.engine.iqRecorder
        #expect(await eventually { r.headFrame > 20_000 })   // some IQ heard at the old hardware frequency
        let center = m.centerHz
        let before = r.headFrame
        m.setUpconverter(true)
        #expect(m.centerHz == center)   // the same display centre: the IQ context compares equal
        let after = r.headFrame
        #expect(await eventually { r.headFrame > after + 10_000 })
        let snapshot = r.snapshot(lastSeconds: 5)
        let head = r.headFrame
        #expect((snapshot?.frames ?? 0) > 0)
        #expect((snapshot?.frames ?? .max) <= head - before)
    }

    @Test func setBandwidthClampsToModeRange() {
        let m = makeModel()
        m.setMode(.usb)
        m.setBandwidth(1_000_000)
        #expect(m.bandwidthHz == DemodMode.usb.bandwidthRange.upperBound)
        m.setBandwidth(1)
        #expect(m.bandwidthHz == DemodMode.usb.bandwidthRange.lowerBound)
    }

    @Test func corruptBookmarksBannerNamesRealBackupFile() throws {
        let dir = tempDir()
        try Data("{ nope".utf8).write(to: dir.appendingPathComponent("bookmarks.json"))
        let m = makeModel(dir: dir)
        let message = try #require(m.banner?.message)
        #expect(!message.contains("<timestamp>"))
        #expect(message.contains("bookmarks.corrupt-"))
    }

    @Test func corruptNotPreservedBlocksSaving() throws {
        let dir = tempDir()
        let file = dir.appendingPathComponent("bookmarks.json")
        let garbage = Data("not json".utf8)
        try garbage.write(to: file)
        // Read-only directory: the corrupt file can be neither moved nor copied aside.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        let m = makeModel(dir: dir)
        #expect(m.bookmarks == BookmarkStore.defaults)
        #expect(m.banner?.kind == .error)
        #expect(m.banner?.message == "The bookmarks file is unreadable and could not be backed up. Changes to bookmarks will not be saved until the file is fixed or removed.")

        m.banner = nil
        m.addBookmark()
        #expect(m.bookmarks.count == BookmarkStore.defaults.count + 1)
        #expect(m.banner?.kind == .error)
        #expect(m.banner?.message.hasPrefix("The bookmarks file is unreadable and could not be backed up") == true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        #expect(try Data(contentsOf: file) == garbage)
    }

    @Test func infoBannerDoesNotReplaceError() throws {
        let dir = tempDir()
        try Data("not json".utf8).write(to: dir.appendingPathComponent("bookmarks.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let m = makeModel(dir: dir)
        #expect(m.banner?.kind == .error)
        m.setVFO(20_000) // below 50 kHz: would raise an info banner via retune
        #expect(m.banner?.kind == .error)
    }

    @Test func upconverterChangeReclampsVFOAndCenter() {
        let m = makeModel()
        m.setVFO(1_950_000_000)
        m.setUpconverter(true)
        #expect(m.vfoHz <= 1_875_000_000)
        #expect(abs(m.vfoHz - m.centerHz) <= m.sampleRate * 0.45)
    }
}
