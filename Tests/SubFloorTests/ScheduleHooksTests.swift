import DSPCore
import Foundation
import Recording
import Scheduling
import SDRplayKit
import SubFloorCore
import Testing
@testable import SubFloor

/// The hooks the scheduler drives in the app: schedule recording on Auto's machinery, the run mute, the
/// `.scheduled` label line, the saved radio and its restore, the session written mid-run, and starting on the RSP.
///
/// The RSP is a stand-in (`fakeRSP`, a synthetic source with one AM signal at 10 MHz), so a run never needs the
/// hardware; the real open always fails. A run still needs the audio engine to start: without an audio device
/// those parts are skipped, as AutoRecordControlTests does.
@MainActor
@Suite(.serialized)
struct ScheduleHooksTests {
    private static let tag = ScheduleTag(id: UUID(), name: "Voice of Korea")
    private static let timing = AutoRecordTiming(startAfter: 2, stopAfter: 600)

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorScheduleHooks-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fakeRSP() -> SyntheticSource {
        SyntheticSource(signals: [.init(frequency: 10_000_000, amplitude: 0.05, kind: .am(toneHz: 1_000))])
    }

    private func makeModel(fakeRSP: Bool = true, defaults: UserDefaults? = nil, dir: URL? = nil,
                           openRSP: @escaping @Sendable () throws -> SDRplayDevice = { throw SDRplayError.noDevice })
        -> (AppModel, URL) {
        let dir = dir ?? tempDir()
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: defaults ?? UserDefaults(suiteName: UUID().uuidString)!,
                         openRSP: openRSP, rspOpenTimeout: .seconds(2),
                         decodeHistoryFolder: dir.appendingPathComponent("decodes"),
                         fakeRSP: fakeRSP ? Self.fakeRSP() : nil)
        m.recording.folderPath = dir.appendingPathComponent("rec").path
        return (m, dir)
    }

    /// Runs the main run loop (and so the stats timer) until `done`, for at most `timeout` seconds.
    @discardableResult
    private func wait(upTo timeout: Double, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() >= end { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    /// The model running on the fake RSP, or nil when the engine could not start (no audio device).
    private func runningRSP(_ m: AppModel) -> AppModel? {
        m.useSource(.sdrplay)
        if !m.isRunning { m.start() }
        guard m.isRunning else {
            print("engine did not start (tolerated, no audio device)")
            return nil
        }
        return m
    }

    /// The Demo source running, or nil when the engine could not start (no audio device).
    private func runningDemo(_ m: AppModel) -> AppModel? {
        m.useSource(.synthetic)
        guard m.isRunning else {
            print("engine did not start (tolerated, no audio device)")
            return nil
        }
        return m
    }

    @Test func scheduleRecordingArmsTheRecorderWithItsTiming() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        m.squelchEnabled = true
        m.scheduleRecording = AppModel.ScheduleRecording(tag: Self.tag, timing: Self.timing)
        #expect(m.autoRecordState == .needsRadio)   // a stopped radio says so first
        #expect(m.engine.autoRecorder.config.enabled == false)
        m.scheduleRecording = nil
        guard runningRSP(m) != nil else { return }
        #expect(m.sourceKind == .sdrplay)
        #expect(m.autoRecordState == .off)
        m.scheduleRecording = AppModel.ScheduleRecording(tag: Self.tag, timing: Self.timing)
        #expect(m.engine.autoRecorder.config == AutoRecorder.Config(enabled: true, timing: Self.timing))
        #expect(m.autoRecordState == .scheduled)
        #expect(!m.autoRecordEnabled)   // the owner's Auto is left alone
        #expect(m.recording.autoTiming == AutoRecordTiming())
        #expect(m.isPreventingSleep)
        m.scheduleRecording = nil
        #expect(m.engine.autoRecorder.config == AutoRecorder.Config(enabled: false, timing: AutoRecordTiming()))
        #expect(m.autoRecordState == .off)
        #expect(!m.isPreventingSleep)
    }

    @Test func demoIsNeverRecordedBySchedule() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        guard runningDemo(m) != nil else { return }
        m.squelchEnabled = true
        m.scheduleRecording = AppModel.ScheduleRecording(tag: Self.tag, timing: Self.timing)
        #expect(m.sourceKind == .synthetic)
        #expect(m.engine.autoRecorder.config.enabled == false)
    }

    @Test func scheduledRecordingGetsALabelLine() throws {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        guard runningRSP(m) != nil else { return }
        // The squelch stays off, so the trigger never acts on its own: the session is started by hand below.
        m.scheduleRecording = AppModel.ScheduleRecording(tag: Self.tag, timing: Self.timing)
        let recorder = m.engine.audioRecorder
        recorder.start(fromFrame: recorder.headFrame)
        #expect(wait(upTo: 5) { m.isAutoRecording && m.recordingStatus[.audio]?.url != nil })
        let status = try #require(m.recordingStatus[.audio])
        let file = try #require(status.url).lastPathComponent
        let entries = try m.recordingLog.entries(forUTCDay: try #require(status.startedAt))
        #expect(entries.count == 2, "\(entries)")
        if case .autoStarted(let started, _, _, _) = entries.first { #expect(started == file) }
        else { Issue.record("expected the auto start first, got \(entries)") }
        #expect(entries.last == .scheduled(file: file, scheduleID: Self.tag.id, name: "Voice of Korea"))
        // The library names it.
        #expect(wait(upTo: 5) { m.library.catalog.recording(file)?.scheduleName == "Voice of Korea" })
    }

    @Test func scheduleMuteSilencesTheLiveAudio() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        m.volume = 0.7
        #expect(m.effectiveVolume == 0.7)
        m.scheduleMuted = true
        #expect(m.effectiveVolume == 0)
        #expect(m.volume == 0.7)
        m.scheduleMuted = false
        #expect(m.effectiveVolume == 0.7)
    }

    @Test func saveAndFullRestore() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        // The owner's radio: the RSP chosen, stopped, AM a little off the capture's usual spot, an agent's Auto.
        m.tune(to: 10_000_000)
        m.setVFO(10_050_000)
        m.setMode(.am)
        m.setBandwidth(6_000)
        m.squelchEnabled = true
        m.squelchDb = -90
        let offAt = Date().addingTimeInterval(3_600)
        m.turnOnAutoRecord(until: offAt)
        let saved = m.saveRadio()
        #expect(saved == AppModel.SavedRadio(vfoHz: 10_050_000, centerHz: m.centerHz, mode: .am, bandwidthHz: 6_000,
                                             squelchEnabled: true, squelchDb: -90, autoRecord: true, autoRecordOffAt: offAt,
                                             upconverter: false, source: .sdrplay, running: false))
        #expect(m.centerHz != 10_050_000 - TuningPlanner.dcOffset(sampleRate: m.sampleRate))   // a VFO moved within the capture

        // A run changes all of it.
        m.setUpconverter(true)
        m.useSource(.synthetic)   // starts the demo, if there is audio
        m.tune(to: 135_000_000)
        m.setMode(.lsb)
        m.squelchEnabled = false
        m.squelchDb = -60
        m.autoRecordEnabled = false
        m.scheduleMuted = true

        m.restoreRadio(saved, full: true)
        #expect(m.saveRadio() == saved)
        #expect(!m.isRunning)
        #expect(!m.scheduleMuted)
        #expect(m.autoRecordOffAt == offAt)

        // Saved running on the RSP: it runs on the RSP again.
        guard runningRSP(m) != nil else { return }
        let running = m.saveRadio()
        #expect(running.running && running.source == .sdrplay)
        m.useSource(.synthetic)
        m.stop()
        m.restoreRadio(running, full: true)
        #expect(m.isRunning)
        #expect(m.sourceKind == .sdrplay)
        #expect(m.saveRadio() == running)
    }

    @Test func partialRestoreLeavesTheOwnersTuning() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        m.tune(to: 7_100_000)
        m.setMode(.lsb)
        m.squelchDb = -95
        let saved = m.saveRadio()   // squelch off, Auto off, HamItUp off

        // The run, then the owner takes over mid-way.
        m.useSource(.synthetic)
        m.tune(to: 9_435_000)
        m.setMode(.am)
        m.squelchEnabled = true
        m.squelchDb = -70
        m.autoRecordEnabled = true
        m.setUpconverter(true)
        m.scheduleMuted = true
        let vfo = m.vfoHz, centre = m.centerHz, running = m.isRunning

        m.restoreRadio(saved, full: false)
        #expect(!m.squelchEnabled)
        #expect(m.squelchDb == -95)
        #expect(!m.autoRecordEnabled)
        #expect(m.autoRecordOffAt == nil)
        #expect(!m.upconverter.enabled)
        #expect(!m.scheduleMuted)
        // The owner's tuning, mode, source and running stay as they left them.
        #expect(m.vfoHz == vfo)
        #expect(m.centerHz == centre)
        #expect(m.mode == .am)
        #expect(m.preferredSource == .synthetic)
        #expect(m.isRunning == running)
    }

    @Test func sessionSavedMidRunIsTheOwnersRadio() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let (m, dir) = makeModel(defaults: defaults)
        m.tune(to: 7_100_000)
        m.squelchEnabled = true
        m.squelchDb = -95
        m.autoRecordEnabled = true
        let owner = m.saveRadio()
        m.sessionRadioOverride = owner
        // The run's radio, and a change of the owner's that is not the radio's.
        m.tune(to: 9_435_000)
        m.setMode(.am)
        m.squelchDb = -70
        m.autoRecordEnabled = false
        m.volume = 0.3
        m.shutdown()   // saves the session, as a quit mid-run would

        let (again, _) = makeModel(defaults: defaults, dir: dir)
        defer { again.shutdown() }
        #expect(again.vfoHz == owner.vfoHz)
        #expect(again.centerHz == owner.centerHz)
        #expect(again.mode == owner.mode)
        #expect(again.bandwidthHz == owner.bandwidthHz)
        #expect(again.squelchEnabled)
        #expect(again.squelchDb == -95)
        #expect(again.autoRecordEnabled)
        #expect(again.volume == 0.3)   // the rest of the session is live
    }

    @Test func startRSPForScheduleUsesTheFakeRSP() async {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        guard runningDemo(m) != nil else { return }
        #expect(await m.startRSPForSchedule(timeout: .seconds(5)))
        #expect(m.isRunning)
        #expect(m.sourceKind == .sdrplay)
        #expect(m.preferredSource == .sdrplay)
        #expect(m.deviceName == "Test RSP")
        // Already on it: true again, nothing restarted.
        #expect(await m.startRSPForSchedule(timeout: .seconds(5)))
    }

    @Test func startRSPForScheduleFailsWithoutAnRSP() async {
        // The open fails at once: the radio falls back to the demo, which is not the RSP.
        let (m, _) = makeModel(fakeRSP: false)
        defer { m.shutdown() }
        m.useSource(.synthetic)
        let running = m.isRunning
        #expect(await m.startRSPForSchedule(timeout: .seconds(5)) == false)
        #expect(m.preferredSource == .synthetic)
        #expect(m.isRunning == running)
        #expect(m.sourceKind == .synthetic)

        // The open never returns within the timeout: the same, stopped this time.
        let (stuck, _) = makeModel(fakeRSP: false, openRSP: {
            Thread.sleep(forTimeInterval: 1)
            throw SDRplayError.noDevice
        })
        defer { stuck.shutdown() }
        stuck.useSource(.synthetic)
        stuck.stop()
        #expect(await stuck.startRSPForSchedule(timeout: .milliseconds(300)) == false)
        #expect(stuck.preferredSource == .synthetic)
        #expect(!stuck.isRunning)
    }

    @Test func theScheduleNameLeadsTheLabels() {
        var r = CatalogRecording(file: "SubFloor_20261103_120000Z_9435000Hz_AM.flac", start: Date(timeIntervalSince1970: 1_793_707_200),
                                 seconds: 60, frequencyHz: 9_435_000, mode: "AM", auto: true, heard: false, inProgress: false,
                                 laneID: "9435000 AM")
        #expect(PlayerPanel.title(r) == "9.435 MHz AM")
        #expect(SubFloorTools.recordingJSON(r, nil)["schedule"] == .null)
        let plain = DayTimelineView.hoverText(r)
        r.scheduleName = "Voice of Korea"
        #expect(PlayerPanel.title(r) == "Voice of Korea · 9.435 MHz AM")
        #expect(DayTimelineView.hoverText(r) == plain.replacingOccurrences(of: "9.435 MHz AM", with: "Voice of Korea · 9.435 MHz AM"))
        #expect(SubFloorTools.recordingJSON(r, nil)["schedule"]?.string == "Voice of Korea")
    }

    @Test func lowDiskEndsAScheduledRecording() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        m.freeSpaceProbe = { _ in 50_000_000 }
        var stops = 0
        m.onLowDiskStop = { stops += 1 }
        m.scheduleRecording = AppModel.ScheduleRecording(tag: Self.tag, timing: Self.timing)
        m.checkRecordingsDiskSpace()   // Auto is off: the check runs for the schedule
        #expect(stops == 1)
        #expect(m.scheduleRecording == nil)
        #expect(m.banner?.kind == .error)
        m.checkRecordingsDiskSpace()
        #expect(stops == 1)
    }

    @Test func aLostRSPIsNotedAndTheFakeIsGone() async throws {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        #expect(m.rspLostAt == nil)
        guard runningRSP(m) != nil else { return }
        let before = Date()
        m.simulateDeviceRemovedForTesting()
        #expect(!m.isRunning)
        #expect(try #require(m.rspLostAt) >= before)
        #expect(m.banner?.message == "RSP1B disconnected.")
        // The fake is no longer an open RSP: a restart opens one (and fails, so the demo runs).
        m.start()
        for _ in 0..<100 where !m.rspOpenFailed { try await Task.sleep(for: .milliseconds(50)) }   // the open's answer is a main-actor task
        #expect(m.rspOpenFailed)
        #expect(m.sourceKind != .sdrplay || !m.isRunning)
    }
}
