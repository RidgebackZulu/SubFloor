import DSPCore
import Foundation
import Recording
import SubFloorCore
import Testing
@testable import SubFloor

/// The app side of recording: the quick actions, the settings round trip, and a whole recording
/// from the demo source into files.
@MainActor
@Suite(.serialized)
struct RecordingControlTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorRecTests-\(UUID().uuidString)", isDirectory: true)
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

    @Test func recordingNeedsTheRadioRunning() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        m.startRecording(.audio)
        #expect(!m.isRecording(.audio))
        #expect(m.banner?.message.contains("Start the radio") == true)
    }

    @Test func settingsStayValidAndPersist() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let (m, dir) = makeModel(defaults: defaults)
        m.recording.audioFormat = .flac
        m.recording.audioSampleFormat = .float32   // FLAC cannot hold float
        #expect(m.recording.audioSampleFormat == .int24)
        m.recording.preRollSeconds = 45
        m.recording.iqFormat = .sigmf
        m.shutdown()   // saves the session
        let again = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")), defaults: defaults)
        defer { again.shutdown() }
        #expect(again.recording.preRollSeconds == 45)
        #expect(again.recording.iqFormat == .sigmf)
        #expect(again.recording.folderPath == dir.appendingPathComponent("rec").path)
    }

    @Test func bothRecordsAudioAndIQFromTheDemoSourceIntoFiles() throws {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        m.recording.preRollSeconds = 5
        m.recording.iqSampleFormat = .int16
        m.useSource(.synthetic)
        guard m.isRunning else {
            print("engine did not start (tolerated, no audio device)")
            return
        }
        wait(0.5)   // some pre-roll (a debug build's demo source runs slower than real time)
        let primed = m.engine.iqRecorder.status.preRollFill * m.recording.preRollSeconds
        #expect(primed > 0.05)
        let click = Date()
        m.toggleRecordingBoth()
        #expect(m.isRecording(.audio) && m.isRecording(.iq) && m.isRecordingAll)
        wait(0.6)
        m.toggleRecordingBoth()   // all on: stops both
        wait(0.5)
        #expect(!m.isRecordingAny)
        let iq = m.recordingStatus[.iq]!, audio = m.recordingStatus[.audio]!
        #expect(iq.error == nil && audio.error == nil)
        // The files start as far before the click as the pre-roll had primed, then run to the stop.
        for s in [iq, audio] {
            let before = click.timeIntervalSince(s.startedAt!)
            #expect(abs(before - primed) < 0.15)
            #expect(s.duration > before + 0.1 && s.duration < 3)
        }
        #expect(iq.url?.lastPathComponent.hasSuffix("Hz_IQ.wav") == true)
        #expect(audio.url?.lastPathComponent.hasSuffix("Hz_USB.flac") == true)
        // The IQ file is one SubFloor itself can open, at the demo rate and with the centre in its name.
        let source = try IQFileSource(url: iq.url!, centerFrequency: 0)
        #expect(source.sampleRate == m.sampleRate)
        #expect(source.frameCount == iq.framesWritten)
        #expect(AppModel.centerFrequency(fromFileName: iq.url!.lastPathComponent) == m.centerHz)
    }

    @Test func stoppingTheRadioFinalisesRecordings() {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        m.useSource(.synthetic)
        guard m.isRunning else { return }
        m.startRecording(.audio)
        #expect(m.isRecording(.audio))
        m.stop()
        #expect(!m.isRecording(.audio))
        #expect(m.recordingStatus[.audio]?.url != nil)
        #expect(FileManager.default.fileExists(atPath: m.recordingStatus[.audio]!.url!.path))
    }
}
