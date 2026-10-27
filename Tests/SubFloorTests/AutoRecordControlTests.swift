import DSPCore
import Foundation
import Recording
import SubFloorCore
import Testing
@testable import SubFloor

/// The app side of auto-record: its states, what the engine is told, persistence, the hand-over
/// between the Audio button and an auto recording, the log, and the guards for unattended running.
///
/// Auto sessions are started directly on the engine's audio recorder (`start(fromFrame:)`) while the
/// Demo source runs; the engine's AutoRecorder is disabled on the Demo source, so it never interferes.
@MainActor
@Suite(.serialized)
struct AutoRecordControlTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorAutoTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeModel(defaults: UserDefaults? = nil) -> (AppModel, URL) {
        let dir = tempDir()
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: defaults ?? UserDefaults(suiteName: UUID().uuidString)!)
        m.recording.folderPath = dir.appendingPathComponent("rec").path
        return (m, dir)
    }

    private func wait(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
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

    /// The Demo source running, or nil when the engine could not start (no audio device).
    private func runningDemo(_ m: AppModel) -> AppModel? {
        m.useSource(.synthetic)
        guard m.isRunning else {
            print("engine did not start (tolerated, no audio device)")
            return nil
        }
        return m
    }

    /// Starts an auto session on the audio recorder at its head, as the trigger would, and waits
    /// until the model shows it.
    private func startAutoSession(_ m: AppModel) -> Bool {
        let recorder = m.engine.audioRecorder
        recorder.start(fromFrame: recorder.headFrame)
        return wait(upTo: 5) { m.isAutoRecording && m.recordingStatus[.audio]?.url != nil }
    }

    @Test func autoNeedsTheSquelch() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        #expect(m.autoRecordState == .off)
        m.toggleAutoRecord()
        #expect(m.autoRecordEnabled)
        #expect(m.banner?.message == "Auto-record needs the squelch on.")
        #expect(m.banner?.kind == .info)
        guard runningDemo(m) != nil else { return }
        m.setSourceKindForTesting(.file)   // a source Auto may record: only the squelch is missing
        #expect(m.autoRecordState == .needsSquelch)
        #expect(m.engine.autoRecorder.config.enabled == false)
        m.squelchEnabled = true
        #expect(m.autoRecordState == .armed)
        #expect(m.engine.autoRecorder.config.enabled)
        m.squelchEnabled = false
        #expect(m.engine.autoRecorder.config.enabled == false)
    }

    @Test func autoIsOffWhileTheRadioIsStopped() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        m.squelchEnabled = true
        m.autoRecordEnabled = true
        #expect(m.autoRecordState == .needsRadio)
        #expect(m.engine.autoRecorder.config.enabled == false)
        #expect(!m.isPreventingSleep)
    }

    @Test func demoSourceNeverTriggers() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        guard runningDemo(m) != nil else { return }
        m.squelchEnabled = true
        m.toggleAutoRecord()
        #expect(m.autoRecordEnabled)
        #expect(m.autoRecordState == .demoSource)
        #expect(m.engine.autoRecorder.config.enabled == false)
        // Auto is on and the radio runs: the Mac must not idle to sleep, whatever the source.
        #expect(m.isPreventingSleep)
        m.stop()
        #expect(m.autoRecordState == .needsRadio)
        #expect(!m.isPreventingSleep)
    }

    @Test func autoSettingsAndSquelchPersist() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let (m, dir) = makeModel(defaults: defaults)
        m.autoRecordEnabled = true
        m.squelchEnabled = true
        m.squelchDb = -97
        m.recording.autoTiming = AutoRecordTiming(startAfter: 3, stopAfter: 60)
        m.shutdown()   // saves the session
        let again = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")), defaults: defaults)
        defer { again.shutdown() }
        #expect(again.autoRecordEnabled)
        #expect(again.squelchEnabled)
        #expect(again.squelchDb == -97)
        #expect(again.recording.autoTiming == AutoRecordTiming(startAfter: 3, stopAfter: 60))
        #expect(again.autoRecordState == .needsRadio)   // restored, but the radio is not started at launch
    }

    @Test func aSessionSavedBeforeAutoRecordStillRestores() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let (m, dir) = makeModel(defaults: defaults)
        m.recording.preRollSeconds = 45
        m.shutdown()
        // Strip everything this feature added, as an older SubFloor would have saved it.
        let saved = try #require(defaults.data(forKey: "session"))
        var session = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        for key in ["autoRecord", "squelchEnabled", "squelchDb"] { session[key] = nil }
        var recording = try #require(session["recording"] as? [String: Any])
        recording["autoTiming"] = nil
        session["recording"] = recording
        defaults.set(try JSONSerialization.data(withJSONObject: session), forKey: "session")
        let again = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")), defaults: defaults)
        defer { again.shutdown() }
        #expect(again.recording.preRollSeconds == 45)
        #expect(again.recording.autoTiming == AutoRecordTiming())
        #expect(!again.autoRecordEnabled)
    }

    @Test func audioButtonTakesOverAnAutoRecording() throws {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        guard runningDemo(m) != nil else { return }
        wait(0.3)
        #expect(startAutoSession(m))
        let url = m.recordingStatus[.audio]?.url
        // The Audio and Both buttons ignore an auto recording.
        #expect(!m.isRecording(.audio))
        #expect(!m.isRecordingAny)
        m.toggleRecording(.audio)
        #expect(m.recordingStatus[.audio]?.isRecording == true)
        #expect(m.recordingStatus[.audio]?.isAuto == false)
        #expect(m.isRecording(.audio))
        #expect(!m.isAutoRecording)
        wait(0.3)
        #expect(m.recordingStatus[.audio]?.url == url)   // the same file, now manual
        #expect(m.recordingStatus[.audio]?.filesWritten == 1)
        m.toggleRecording(.audio)
        #expect(wait(upTo: 5) { m.recordingStatus[.audio]?.isRecording == false })
        // A recording taken over by the Audio button is logged as manual.
        let status = try #require(m.recordingStatus[.audio])
        let entries = try m.recordingLog.entries(forUTCDay: try #require(status.startedAt))
        #expect(entries.count == 1)
        if case .recording(let file, _, _, _, _, let auto) = entries.first {
            #expect(file == url?.lastPathComponent)
            #expect(!auto)
        } else {
            Issue.record("expected a recording entry, got \(entries)")
        }
    }

    @Test func changingStopAfterDoesNotEndARecording() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        guard runningDemo(m) != nil else { return }
        #expect(startAutoSession(m))
        let url = m.recordingStatus[.audio]?.url
        let plan = m.engine.audioRecorder.ringPlan
        m.recording.autoTiming.stopAfter = 120
        m.recording.autoTiming.startAfter = 5
        #expect(m.engine.autoRecorder.config.timing == AutoRecordTiming(startAfter: 5, stopAfter: 120))
        #expect(m.engine.audioRecorder.ringPlan == plan)
        m.engine.audioRecorder.commit(throughFrame: m.engine.audioRecorder.headFrame)
        wait(0.4)
        #expect(m.isAutoRecording)
        #expect(m.recordingStatus[.audio]?.url == url)
        #expect(m.recordingStatus[.audio]?.filesWritten == 1)
    }

    @Test func theAudioRingAlwaysHoldsTheLongestHoldbackAndTheFullPreRoll() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        m.recording.audioFormat = .wav
        m.recording.audioSampleFormat = .float32   // the largest sample
        m.recording.preRollSeconds = RecordingSettings.preRollRange.upperBound
        #expect(m.engine.audioRecorder.setup?.holdbackSeconds == AutoRecordTiming.maxHoldbackSeconds)
        #expect(m.engine.audioRecorder.effectivePreRollSeconds == RecordingSettings.preRollRange.upperBound)
    }

    @Test func stoppingTheRadioLogsTheAutoRecording() throws {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        guard runningDemo(m) != nil else { return }
        let vfo = m.vfoHz, mode = m.mode.label
        wait(0.3)
        #expect(startAutoSession(m))
        let recorder = m.engine.audioRecorder
        recorder.commit(throughFrame: recorder.headFrame)
        #expect(wait(upTo: 5) { (m.recordingStatus[.audio]?.framesWritten ?? 0) > 0 })
        m.stop()
        let status = try #require(m.recordingStatus[.audio])
        #expect(!status.isRecording)
        let entries = try m.recordingLog.entries(forUTCDay: try #require(status.startedAt))
        let recordings = entries.filter { if case .recording = $0 { true } else { false } }
        #expect(recordings.count == 1)
        guard case .recording(let file, let start, let seconds, let hz, let label, let auto) = recordings.first else { return }
        #expect(auto)
        #expect(file == status.url?.lastPathComponent)
        #expect(abs(start.timeIntervalSince(status.startedAt!)) < 0.002)   // the log keeps milliseconds
        #expect(seconds == status.duration && seconds > 0)
        #expect(hz == vfo && label == mode)
        #expect(FileManager.default.fileExists(atPath: m.recording.folder.appendingPathComponent(file).path))
    }

    /// Waits on the recorder itself, without running the run loop, so the model's timer does not poll.
    private func spin(upTo timeout: Double, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() >= end { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }

    /// An auto session at the head with everything so far committed, written to a file; no poll.
    private func recordUnseen(_ recorder: StreamRecorder) -> Bool {
        let first = recorder.headFrame
        recorder.start(fromFrame: first)
        guard spin(upTo: 5, until: { recorder.headFrame > first + 2_400 }) else { return false }   // 50 ms of audio
        recorder.commit(throughFrame: recorder.headFrame)
        return spin(upTo: 5) { recorder.status.framesWritten > 0 && recorder.status.url != nil }
    }

    private func recordings(_ entries: [RecordingLogEntry]) -> [(file: String, hz: Double, auto: Bool)] {
        entries.compactMap { if case .recording(let file, _, _, let hz, _, let auto) = $0 { (file, hz, auto) } else { nil } }
    }

    @Test func aRecordingReplacedBetweenTwoPollsIsLoggedWithItsOwnTuning() throws {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        guard runningDemo(m) != nil else { return }
        let recorder = m.engine.audioRecorder
        let firstVFO = m.vfoHz
        #expect(recordUnseen(recorder))
        m.refreshRecordingStatus()   // A is seen recording
        #expect(m.isAutoRecording)
        let a = try #require(m.recordingStatus[.audio])
        m.stepVFO(1)
        let secondVFO = m.vfoHz
        recorder.stop(wait: true)
        #expect(recordUnseen(recorder))
        m.refreshRecordingStatus()   // B, never having seen A end
        let b = try #require(recorder.status.url)
        #expect(b != a.url)
        recorder.stop(wait: true)
        m.refreshRecordingStatus()
        m.refreshRecordingStatus()   // nothing is logged twice

        let logged = recordings(try m.recordingLog.entries(forUTCDay: try #require(a.startedAt)))
        #expect(logged.map(\.file) == [a.url!.lastPathComponent, b.lastPathComponent])
        #expect(logged.map(\.hz) == [firstVFO, secondVFO])
        #expect(logged.allSatisfy { $0.auto })
    }

    @Test func aRecordingThatCameAndWentBetweenTwoPollsIsLogged() throws {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        guard runningDemo(m) != nil else { return }
        let recorder = m.engine.audioRecorder
        m.refreshRecordingStatus()
        #expect(recordUnseen(recorder))
        recorder.stop(wait: true)
        m.refreshRecordingStatus()   // first sight of it, already ended
        m.refreshRecordingStatus()
        let status = recorder.status
        #expect(!status.isRecording)
        let logged = recordings(try m.recordingLog.entries(forUTCDay: try #require(status.startedAt)))
        #expect(logged.count == 1)
        #expect(logged.first?.file == status.url?.lastPathComponent)
        #expect(logged.first?.hz == m.vfoHz)
        #expect(logged.first?.auto == true)
    }

    @Test func vfoChangeCutsAndCentreRetuneDoesNot() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        let auto = m.engine.autoRecorder
        var before = auto.cuts
        m.stepVFO(1)
        #expect(auto.cuts == before + 1)
        before = auto.cuts
        m.setMode(m.mode == .usb ? .lsb : .usb)
        #expect(auto.cuts == before + 1)
        before = auto.cuts
        // Recentre the capture on the same VFO.
        let vfo = m.vfoHz, centre = m.centerHz
        m.tune(to: vfo)
        #expect(m.vfoHz == vfo && m.centerHz != centre)
        #expect(auto.cuts == before)
        // Neither does a receiver change that keeps the frequency and mode.
        m.squelchDb = -90
        m.setBandwidth(m.bandwidthHz + 100)
        #expect(auto.cuts == before)
    }

    @Test func lowDiskWarnsOnceAndThenTurnsAutoOff() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        var free: Int64 = 300_000_000
        m.freeSpaceProbe = { _ in free }
        m.autoRecordEnabled = true
        m.checkRecordingsDiskSpace()
        #expect(m.banner?.kind == .warning)
        #expect(m.banner?.message == "Less than 500 MB free where recordings go.")
        m.banner = nil
        m.checkRecordingsDiskSpace()
        #expect(m.banner == nil)   // once per crossing
        free = 600_000_000
        m.checkRecordingsDiskSpace()
        free = 400_000_000
        m.checkRecordingsDiskSpace()
        #expect(m.banner?.kind == .warning)   // crossed again
        free = 50_000_000
        m.checkRecordingsDiskSpace()
        #expect(!m.autoRecordEnabled)
        #expect(m.banner?.kind == .error)
        #expect(m.banner?.message == "Auto-record is off: less than 100 MB free where recordings go.")
    }

    @Test func lowDiskStopsAnAutoRecordingButNotAManualOne() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        guard runningDemo(m) != nil else { return }
        m.freeSpaceProbe = { _ in 50_000_000 }
        m.startRecording(.audio)
        m.autoRecordEnabled = true
        m.checkRecordingsDiskSpace()
        #expect(!m.autoRecordEnabled)
        wait(0.3)
        #expect(m.isRecording(.audio))   // a manual recording is the listener's to stop
        m.stopRecording(.audio)
        #expect(wait(upTo: 5) { m.recordingStatus[.audio]?.isRecording == false })
        m.autoRecordEnabled = true
        #expect(startAutoSession(m))
        m.checkRecordingsDiskSpace()
        #expect(!m.autoRecordEnabled)
        #expect(wait(upTo: 5) { m.recordingStatus[.audio]?.isRecording == false })
    }
}
