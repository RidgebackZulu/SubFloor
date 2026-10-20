import DSPCore
import Foundation
import SubFloorCore
import Testing
@testable import SubFloor

@MainActor
struct AppModelTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeModel(dir: URL? = nil) -> AppModel {
        let dir = dir ?? tempDir()
        return AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                        defaults: UserDefaults(suiteName: UUID().uuidString)!)
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

    @Test func setBandwidthClampsToModeRange() {
        let m = makeModel()
        m.setMode(.usb)
        m.setBandwidth(1_000_000)
        #expect(m.bandwidthHz == DemodMode.usb.bandwidthRange.upperBound)
        m.setBandwidth(1)
        #expect(m.bandwidthHz == DemodMode.usb.bandwidthRange.lowerBound)
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
