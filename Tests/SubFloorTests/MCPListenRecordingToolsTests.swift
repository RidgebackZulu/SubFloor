import DSPCore
import Foundation
import Modems
import Recording
import SubFloorCore
import Testing
import Transcription
@testable import SubFloor

/// A `TranscribeFunction` for `listen`: answers with the saved reply of the "clock" voice recording and notes
/// each call and the size of the file it was given. Never touches the network.
final class ListenTranscriber: @unchecked Sendable {
    /// How long each call takes, as a slow network would.
    let delay: Duration
    private let lock = NSLock()

    init(delay: Duration = .zero) { self.delay = delay }
    private var _calls: [(file: String, bytes: Int, model: String, language: String?)] = []
    var calls: Int { lock.withLock { _calls.count } }
    var lastBytes: Int { lock.withLock { _calls.last?.bytes ?? 0 } }
    var lastModel: String? { lock.withLock { _calls.last?.model } }

    static let voiceFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TranscriptionTests/Fixtures/SubFloor_20261028_140122Z_11175000Hz_USB.json")

    var function: TranscribeFunction {
        { [self] file, url, model, language, _ in
            let bytes = (try? Data(contentsOf: url).count) ?? 0
            lock.withLock { _calls.append((file, bytes, model, language)) }
            if delay > .zero { try await Task.sleep(for: delay) }
            let reply = try JSONDecoder().decode(WhisperResponse.self, from: try Data(contentsOf: Self.voiceFixture))
            return StoredTranscript(file: file, model: model, language: language, createdAt: Date(),
                                    durationSeconds: reply.duration ?? 0, costUSD: reply.usage?.cost, note: nil,
                                    chunks: [TranscriptChunk(offsetSeconds: 0, response: reply)])
        }
    }
}

/// `listen`, recording, Auto, the decoder and the transcript and decode queries, called as an agent would, on
/// demo-source models whose recordings folder and decode history are temp folders.
@MainActor
@Suite(.serialized)
struct MCPListenRecordingToolsTests {
    private func makeModel(key: String? = "sk-or-test", transcriber: ListenTranscriber = ListenTranscriber(),
                           defaults: UserDefaults? = nil) -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorListenTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: defaults ?? UserDefaults(suiteName: UUID().uuidString)!,
                         apiKeyStore: MemoryAPIKeyStore(key: key), transcribe: transcriber.function,
                         openRSP: { throw CancellationError() }, rspOpenTimeout: .seconds(10),
                         decodeHistoryFolder: dir.appendingPathComponent("decodes"))
        m.recording.folderPath = dir.appendingPathComponent("rec").path
        return (m, dir.appendingPathComponent("rec"))
    }

    /// The demo source running, or false when the engine could not start (no audio device).
    private func runDemo(_ m: AppModel) -> Bool {
        m.useSource(.synthetic)
        if !m.isRunning { print("engine did not start (tolerated, no audio device)") }
        return m.isRunning
    }

    private func call(_ tools: SubFloorTools, _ name: String, _ arguments: [String: JSONValue] = [:],
                      client: String = "test-agent 1.0") async -> MCPToolResult {
        await tools.call(name, arguments: arguments, client: client)
    }

    /// Waits (letting the main actor run) until `condition` holds or `seconds` pass.
    private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return condition() }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    // MARK: listen

    @Test func listenReportsLevelsAndTranscribesWhenOn() async {
        let fake = ListenTranscriber()
        let (m, _) = makeModel(transcriber: fake)
        defer { m.shutdown() }
        guard runDemo(m) else { return }
        m.transcriptionSettings.enabled = true
        let tools = SubFloorTools(model: m)
        let r = await call(tools, "listen", ["seconds": .number(2)])
        #expect(!r.isError, "\(r.content)")
        let s = r.structured
        #expect(s?["transcribed"]?.bool == true)
        #expect(s?["transcript"]?["verdict"]?.string == "voice")
        #expect(s?["transcript"]?["text"]?.string?.isEmpty == false)
        #expect((s?["transcript"]?["words"]?.double ?? 0) >= 3)
        #expect(s?["level_dbfs"]?["median"]?.double?.isFinite == true)
        #expect(s?["level_dbfs"]?["min"]?.double != nil && s?["level_dbfs"]?["max"]?.double != nil)
        #expect((s?["squelch_open_seconds"]?.double ?? -1) >= 0)
        #expect((s?["seconds"]?.double ?? 0) > 0)
        #expect(s?["interrupted"] == nil)
        #expect(fake.calls == 1)
        #expect(fake.lastModel == m.transcriptionSettings.model)
        #expect(fake.lastBytes > 44)   // a 16 kHz WAV with audio in it
        // Nothing kept, nothing logged.
        #expect(m.library.catalog.allRecordings.isEmpty)
    }

    @Test func listenSkipsTranscriptionWhenTheSwitchIsOff() async {
        let fake = ListenTranscriber()
        let (m, _) = makeModel(transcriber: fake)
        defer { m.shutdown() }
        guard runDemo(m) else { return }
        m.transcriptionSettings.enabled = false
        let tools = SubFloorTools(model: m)
        let r = await call(tools, "listen", ["seconds": .number(2)])
        #expect(!r.isError, "\(r.content)")
        #expect(r.structured?["transcribed"]?.bool == false)
        #expect(r.structured?["transcript"] == nil)
        #expect(r.structured?["note"]?.string?.contains("Transcribe Recordings") == true)
        #expect(fake.calls == 0)

        // On, but no key; on with a key, but the agent said no.
        m.transcriptionSettings.enabled = true
        try? m.removeAPIKey()
        let noKey = await call(tools, "listen", ["seconds": .number(2)])
        #expect(noKey.structured?["transcribed"]?.bool == false)
        #expect(noKey.structured?["note"]?.string?.contains("key") == true)
        try? m.saveAPIKey("sk-or-test")
        let declined = await call(tools, "listen", ["seconds": .number(2), "transcribe": .bool(false)])
        #expect(declined.structured?["transcribed"]?.bool == false)
        #expect(declined.structured?["note"] != nil)
        #expect(fake.calls == 0)
    }

    @Test func listenNeedsTheRadio() async {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        let r = await call(SubFloorTools(model: m), "listen", ["seconds": .number(2)])
        #expect(r.isError)
        #expect(r.content.contains("start_radio"))
    }

    @Test func listenStopsWhenTheOwnerRetunes() async throws {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        guard runDemo(m) else { return }
        let tools = SubFloorTools(model: m)
        let started = ContinuousClock.now
        let listening = Task { @MainActor in await call(tools, "listen", ["seconds": .number(10)]) }
        try await Task.sleep(for: .milliseconds(500))
        m.tune(to: 7_200_000)
        let r = await listening.value
        #expect(ContinuousClock.now - started < .seconds(1.5))
        #expect(!r.isError, "\(r.content)")
        #expect(r.structured?["interrupted"]?.string == "retuned to \(FrequencyFormatter.short(7_200_000)) by the owner")
        #expect(r.structured?["interrupted"]?.string?.hasPrefix("retuned to") == true)
    }

    /// Another agent's tune is not held up by a listen: it goes through at once, and the listen stops and names it.
    @Test func listenStopsWhenAnotherAgentRetunes() async throws {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        guard runDemo(m) else { return }
        let tools = SubFloorTools(model: m)
        let started = ContinuousClock.now
        let listening = Task { @MainActor in await call(tools, "listen", ["seconds": .number(10)], client: "agent-a 1.0") }
        try await Task.sleep(for: .milliseconds(500))
        let tuneStarted = ContinuousClock.now
        let tune = await call(tools, "tune", ["frequency": .string("7.2 MHz")], client: "claude-code 2.1")
        #expect(ContinuousClock.now - tuneStarted < .milliseconds(500))
        #expect(!tune.isError, "\(tune.content)")
        #expect(m.vfoHz == 7_200_000)
        let r = await listening.value
        #expect(ContinuousClock.now - started < .seconds(1.5))
        #expect(r.structured?["interrupted"]?.string == "retuned to \(FrequencyFormatter.short(7_200_000)) by claude-code 2.1")
        // The owner's change after the agent's is the owner's.
        let again = Task { @MainActor in await call(tools, "listen", ["seconds": .number(10)], client: "agent-a 1.0") }
        try await Task.sleep(for: .milliseconds(300))
        m.tune(to: 7_250_000)
        #expect(await again.value.structured?["interrupted"]?.string?.hasSuffix("by the owner") == true)
    }

    /// A listen that ends, and a read that ends, are not changes: two listens interrupted by the owner both say so.
    @Test func onlyAnAgentsChangeIsCreditedToIt() async throws {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        guard runDemo(m) else { return }
        // A read the test holds open while the owner retunes.
        let release = AsyncStream<Void>.makeStream()
        let slowRead = SubFloorTool("slow_read", title: "Slow read", readOnly: true, description: "Waits.") { _, _, _ in
            for await _ in release.stream { break }
            return [:]
        }
        let tools = SubFloorTools(model: m, extraTools: [slowRead])

        let a = Task { @MainActor in await call(tools, "listen", ["seconds": .number(10)], client: "agent-a 1.0") }
        let c = Task { @MainActor in await call(tools, "listen", ["seconds": .number(10)], client: "agent-c 1.0") }
        try await Task.sleep(for: .milliseconds(400))
        m.tune(to: 7_200_000)
        #expect(await a.value.structured?["interrupted"]?.string == "retuned to \(FrequencyFormatter.short(7_200_000)) by the owner")
        #expect(await c.value.structured?["interrupted"]?.string == "retuned to \(FrequencyFormatter.short(7_200_000)) by the owner")

        let listening = Task { @MainActor in await call(tools, "listen", ["seconds": .number(10)], client: "agent-a 1.0") }
        let read = Task { @MainActor in await call(tools, "slow_read", client: "agent-b 1.0") }
        try await Task.sleep(for: .milliseconds(400))
        m.tune(to: 7_250_000)          // the owner, while agent-b's read waits
        release.continuation.yield()   // the read ends straight after
        _ = await read.value
        #expect(await listening.value.structured?["interrupted"]?.string == "retuned to \(FrequencyFormatter.short(7_250_000)) by the owner")
    }

    @Test func listenStopsWhenTheModeChangesOrTheRadioStops() async throws {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        guard runDemo(m) else { return }
        m.setMode(.usb)
        let tools = SubFloorTools(model: m)
        let first = Task { @MainActor in await call(tools, "listen", ["seconds": .number(10)]) }
        try await Task.sleep(for: .milliseconds(300))
        m.setMode(.am)
        #expect(await first.value.structured?["interrupted"]?.string == "mode changed to AM by the owner")

        let second = Task { @MainActor in await call(tools, "listen", ["seconds": .number(10)]) }
        try await Task.sleep(for: .milliseconds(300))
        m.stop()
        #expect(await second.value.structured?["interrupted"]?.string == "the radio stopped by the owner")
    }

    @Test func listenKeepsTheClipAsARecording() async {
        let fake = ListenTranscriber()
        let (m, folder) = makeModel(transcriber: fake)
        defer { m.shutdown() }
        guard runDemo(m) else { return }
        m.transcriptionSettings.enabled = true
        let tools = SubFloorTools(model: m)
        let r = await call(tools, "listen", ["seconds": .number(2), "keep": .bool(true)])
        #expect(!r.isError, "\(r.content)")
        let file = r.structured?["file"]?.string ?? ""
        let name = RecordingFileName.parse(file)
        #expect(name?.isAudio == true)
        #expect(name?.frequencyHz == m.vfoHz.rounded())
        #expect(name?.label == m.mode.label)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path))
        // In the Recordings window, with the transcript listen made: it is not sent a second time.
        #expect(m.library.catalog.recording(file) != nil)
        #expect(m.library.transcripts.summary(file)?.verdict == .voice)
        #expect(FileManager.default.fileExists(atPath: TranscriptStore.url(for: file, in: folder).path))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(fake.calls == 1)
    }

    /// A clip kept after the radio moved on (here during a slow transcription) is filed under where it was heard.
    @Test func aKeptClipKeepsTheTuningItWasHeardAt() async throws {
        let fake = ListenTranscriber(delay: .seconds(1))
        let (m, folder) = makeModel(transcriber: fake)
        defer { m.shutdown() }
        guard runDemo(m) else { return }
        m.transcriptionSettings.enabled = true
        m.setMode(.usb)
        m.tune(to: 11_175_000)
        let tools = SubFloorTools(model: m)
        let listening = Task { @MainActor in await call(tools, "listen", ["seconds": .number(2), "keep": .bool(true)]) }
        #expect(await eventually(10) { fake.calls == 1 })   // listening is over; the transcript is on its way
        _ = await call(tools, "tune", ["frequency": .string("7.2 MHz"), "mode": .string("lsb")], client: "agent-b 1.0")
        #expect(m.vfoHz == 7_200_000)
        let r = await listening.value
        #expect(!r.isError, "\(r.content)")
        #expect(r.structured?["interrupted"] == nil)
        let file = try #require(r.structured?["file"]?.string)
        #expect(RecordingFileName.parse(file)?.frequencyHz == 11_175_000)
        #expect(RecordingFileName.parse(file)?.label == "USB")
        let rec = try #require(m.library.catalog.recording(file))
        #expect(rec.frequencyHz == 11_175_000)
        #expect(rec.mode == "USB")
        let logged = try RecordingLog(folder: folder).allEntries().contains {
            if case .recording(file, _, _, 11_175_000, "USB", false) = $0 { true } else { false }
        }
        #expect(logged)
        let near = await call(tools, "list_recordings", ["frequency": .string("11.175 MHz"), "tolerance_hz": .number(100)])
        #expect(near.structured?["recordings"]?.array?.compactMap { $0["file"]?.string } == [file])
    }

    // MARK: Recording

    @Test func recordingStopsByItself() async {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        guard runDemo(m) else { return }
        let tools = SubFloorTools(model: m)
        let r = await call(tools, "start_recording", ["kind": .string("audio"), "max_minutes": .number(0.02)])
        #expect(!r.isError, "\(r.content)")
        #expect(r.structured?["started"]?.array == [.string("audio")])
        #expect(r.structured?["stops_at"]?.string != nil)
        #expect(m.isRecording(.audio))
        #expect(await eventually(3) {
            m.refreshRecordingStatus()
            return !m.isRecording(.audio)
        })
    }

    @Test func theTimerLeavesTheOwnersRecording() async throws {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        guard runDemo(m) else { return }
        let tools = SubFloorTools(model: m)
        let r = await call(tools, "start_recording", ["kind": .string("audio"), "max_minutes": .number(0.03)])
        #expect(!r.isError, "\(r.content)")
        // The owner stops the agent's recording and starts one of their own before the agent's would end.
        #expect(await eventually(3) {
            m.refreshRecordingStatus()
            return m.recordingStatus[.audio]?.url != nil
        })
        m.stopRecording(.audio)
        #expect(await eventually(3) {
            m.refreshRecordingStatus()
            return !m.isRecording(.audio)
        })
        m.startRecording(.audio)
        #expect(m.isRecording(.audio))
        try await Task.sleep(for: .seconds(2.5))
        m.refreshRecordingStatus()
        #expect(m.isRecording(.audio))
        // stop_recording leaves the owner's recording too.
        let stop = await call(tools, "stop_recording", ["kind": .string("audio")])
        #expect(!stop.isError)
        #expect(stop.structured?["stopped"]?.array == [])
        m.refreshRecordingStatus()
        #expect(m.isRecording(.audio))
    }

    @Test func stopRecordingStopsTheAgentsRecording() async {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        guard runDemo(m) else { return }
        let tools = SubFloorTools(model: m)
        let r = await call(tools, "start_recording", ["kind": .string("both")])
        #expect(!r.isError, "\(r.content)")
        #expect(Set(r.structured?["started"]?.array?.compactMap(\.string) ?? []) == ["audio", "iq"])
        let stop = await call(tools, "stop_recording")
        #expect(Set(stop.structured?["stopped"]?.array?.compactMap(\.string) ?? []) == ["audio", "iq"])
        #expect(await eventually(3) {
            m.refreshRecordingStatus()
            return !m.isRecordingAny
        })
    }

    @Test func recordingNeedsTheRadio() async {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        let r = await call(SubFloorTools(model: m), "start_recording", ["kind": .string("audio")])
        #expect(r.isError)
        #expect(r.content.contains("start_radio"))
        #expect(!m.isRecording(.audio))
        let bad = await call(SubFloorTools(model: m), "start_recording", ["kind": .string("video")])
        #expect(bad.isError)
    }

    // MARK: Auto

    @Test func autoNeedsSquelchAndTurnsItselfOff() async {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        let tools = SubFloorTools(model: m)
        m.squelchEnabled = false
        let refused = await call(tools, "set_auto_record", ["on": .bool(true)])
        #expect(refused.isError)
        #expect(refused.content.contains("Turn the squelch on first (set_squelch)"))
        #expect(!m.autoRecordEnabled)

        m.squelchEnabled = true
        let r = await call(tools, "set_auto_record", ["on": .bool(true), "minutes": .number(0.02)])
        #expect(!r.isError, "\(r.content)")
        #expect(r.structured?["on"]?.bool == true)
        #expect(r.structured?["auto_state"]?.string == m.autoRecordState.toolName)
        #expect(r.structured?["off_at"]?.string != nil)
        #expect(m.autoRecordEnabled)
        #expect(await eventually(3) { !m.autoRecordEnabled })
    }

    @Test func autoTimerLeavesTheOwnersAuto() async throws {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        let tools = SubFloorTools(model: m)
        m.squelchEnabled = true

        // The owner turns Auto off and on by hand while the agent's timer runs: it stays on.
        _ = await call(tools, "set_auto_record", ["on": .bool(true), "minutes": .number(0.02)])
        m.toggleAutoRecord()
        m.toggleAutoRecord()
        #expect(m.autoRecordEnabled)
        try await Task.sleep(for: .seconds(2))
        #expect(m.autoRecordEnabled)

        // The owner had it on before the agent asked: no timer.
        let r = await call(tools, "set_auto_record", ["on": .bool(true), "minutes": .number(0.02)])
        #expect(!r.isError)
        #expect(r.structured?["off_at"] == nil)
        try await Task.sleep(for: .seconds(2))
        #expect(m.autoRecordEnabled)

        // Nor does an agent turn the owner's Auto off.
        let refused = await call(tools, "set_auto_record", ["on": .bool(false)])
        #expect(refused.isError)
        #expect(refused.content == "Auto was turned on by the owner: left on.")
        #expect(m.autoRecordEnabled)

        // An agent's own Auto it may turn off.
        m.autoRecordEnabled = false
        _ = await call(tools, "set_auto_record", ["on": .bool(true), "minutes": .number(10)])
        let off = await call(tools, "set_auto_record", ["on": .bool(false)])
        #expect(!off.isError, "\(off.content)")
        #expect(off.structured?["on"]?.bool == false)
        #expect(!m.autoRecordEnabled)
        #expect(m.autoRecordOffAt == nil)
    }

    /// The agent's limit is saved with Auto: a relaunch past it turns Auto off, one before it waits for it.
    @Test func autoLimitSurvivesARelaunch() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let (first, _) = makeModel(defaults: defaults)
        first.squelchEnabled = true
        let r = await call(SubFloorTools(model: first), "set_auto_record", ["on": .bool(true), "minutes": .number(0.01)])
        #expect(!r.isError, "\(r.content)")
        first.shutdown()   // quits with Auto on and 0.6 s to go
        try await Task.sleep(for: .seconds(1))
        let (late, _) = makeModel(defaults: defaults)
        #expect(!late.autoRecordEnabled)
        #expect(late.autoRecordOffAt == nil)
        late.shutdown()

        let (second, _) = makeModel(defaults: defaults)
        second.squelchEnabled = true
        _ = await call(SubFloorTools(model: second), "set_auto_record", ["on": .bool(true), "minutes": .number(0.03)])
        let offAt = try #require(second.autoRecordOffAt)
        second.shutdown()   // 1.8 s to go
        let (early, _) = makeModel(defaults: defaults)
        defer { early.shutdown() }
        #expect(early.autoRecordEnabled)
        #expect(abs((early.autoRecordOffAt ?? .distantPast).timeIntervalSince(offAt)) < 0.01)
        #expect(await eventually(4) { !early.autoRecordEnabled })
        #expect(early.autoRecordOffAt == nil)

        // The owner's Auto has no limit to restore.
        early.autoRecordEnabled = true
        early.shutdown()
        let (owners, _) = makeModel(defaults: defaults)
        defer { owners.shutdown() }
        #expect(owners.autoRecordEnabled)
        #expect(owners.autoRecordOffAt == nil)
    }

    // MARK: Decoder and decodes

    @Test func setDecoderOffersOnlyTheOfferedModes() async {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        let tools = SubFloorTools(model: m)
        let ft8 = await call(tools, "set_decoder", ["mode": .string("ft8")])
        #expect(!ft8.isError, "\(ft8.content)")
        #expect(m.modemSettings.mode == .ft8)
        #expect(ft8.structured?["decoder"]?.string == "ft8")
        let rtty = await call(tools, "set_decoder", ["mode": .string("rtty")])
        #expect(rtty.isError)
        for mode in ModemControl.offeredModes { #expect(rtty.content.contains(mode.rawValue)) }
        #expect(m.modemSettings.mode == .ft8)
        let off = await call(tools, "set_decoder", ["mode": .string("off")])
        #expect(off.structured?["decoder"]?.string == "off")
        #expect(m.modemSettings.mode == nil)
    }

    @Test func decodesAndStationsFromHistory() async {
        let (m, _) = makeModel()
        defer { m.shutdown() }
        let tools = SubFloorTools(model: m)
        let slot = Date().addingTimeInterval(-60)
        m.recordSlotDecodes([
            SlotDecode(mode: .ft8, slotStart: slot, frequencyHz: 1_234, snrDb: -7, timeOffset: 0.1, message: "CQ K1ABC FN42"),
            SlotDecode(mode: .ft8, slotStart: slot, frequencyHz: 1_500, snrDb: -12, timeOffset: 0.2, message: "CQ W9XYZ EN52"),
            SlotDecode(mode: .ft8, slotStart: slot.addingTimeInterval(15), frequencyHz: 1_234, snrDb: -3, timeOffset: 0.1,
                       message: "W9XYZ K1ABC -07"),
        ])
        m.decodeHistory.flush()

        let stations = await call(tools, "get_ft8_stations")
        #expect(!stations.isError, "\(stations.content)")
        let rows = stations.structured?["stations"]?.array ?? []
        #expect(rows.count == 2)
        #expect(Set(rows.compactMap { $0["call"]?.string }) == ["K1ABC", "W9XYZ"])
        #expect(rows.allSatisfy { $0["lat"]?.double != nil && $0["lon"]?.double != nil })
        let k1 = rows.first { $0["call"]?.string == "K1ABC" }
        #expect(k1?["count"]?.double == 2)
        #expect(k1?["grid"]?.string == "FN42")
        #expect(k1?["best_snr_db"]?.double == -3)

        let decodes = await call(tools, "get_decodes", ["since_minutes": .number(15)])
        #expect(!decodes.isError, "\(decodes.content)")
        let slotRows = decodes.structured?["decodes"]?.array ?? []
        #expect(slotRows.count == 3)
        #expect(slotRows.first?["message"]?.string == "W9XYZ K1ABC -07")   // newest first
        #expect(decodes.structured?["live"]?.array == [])
        let wspr = await call(tools, "get_decodes", ["mode": .string("wspr")])
        #expect(wspr.structured?["decodes"]?.array == [])
    }

    // MARK: Recordings and transcripts

    /// A transcript sidecar for `file` from one of the Transcription tests' saved replies.
    private func writeTranscript(_ file: String, fixture: String, in folder: URL) throws {
        let url = ListenTranscriber.voiceFixture.deletingLastPathComponent().appendingPathComponent("\(fixture).json")
        let reply = try JSONDecoder().decode(WhisperResponse.self, from: Data(contentsOf: url))
        try TranscriptStore.write(StoredTranscript(file: file, model: "m", language: "en", createdAt: Date(),
                                                   durationSeconds: reply.duration ?? 0, costUSD: nil, note: nil,
                                                   chunks: [TranscriptChunk(offsetSeconds: 0, response: reply)]),
                                  in: folder)
    }

    @Test func listRecordingsFiltersByFrequencyAndVoice() async throws {
        let (m, folder) = makeModel()
        defer { m.shutdown() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date().addingTimeInterval(-3_600)
        func file(_ minutesAgo: Double, _ hz: Double, _ label: String) -> String {
            RecordingNames.base(firstSample: now.addingTimeInterval(-minutesAgo * 60), frequencyHz: hz, label: label) + ".flac"
        }
        let clock = file(30, 11_175_000, "USB"), hiss = file(20, 11_175_000, "USB"), am = file(10, 10_086_000, "AM")
        for f in [clock, hiss, am] { FileManager.default.createFile(atPath: folder.appendingPathComponent(f).path, contents: Data()) }
        try writeTranscript(clock, fixture: "SubFloor_20261028_140122Z_11175000Hz_USB", in: folder)
        try writeTranscript(hiss, fixture: "SubFloor_20261028_134251Z_11175000Hz_USB", in: folder)
        try writeTranscript(am, fixture: "SubFloor_20261028_015603Z_10086000Hz_AM", in: folder)
        await m.library.reload()
        let tools = SubFloorTools(model: m)

        let all = await call(tools, "list_recordings")
        #expect(!all.isError, "\(all.content)")
        #expect(all.structured?["recordings"]?.array?.compactMap { $0["file"]?.string } == [am, hiss, clock])

        let near = await call(tools, "list_recordings", ["frequency": .string("11.178 MHz")])
        #expect(near.structured?["recordings"]?.array?.compactMap { $0["file"]?.string } == [hiss, clock])
        let tight = await call(tools, "list_recordings", ["frequency": .string("11.178 MHz"), "tolerance_hz": .number(1_000)])
        #expect(tight.structured?["recordings"]?.array == [])

        let voice = await call(tools, "list_recordings", ["frequency": .number(11_175_000), "voice_only": .bool(true)])
        let voiceRows = voice.structured?["recordings"]?.array ?? []
        #expect(voiceRows.compactMap { $0["file"]?.string } == [clock])
        #expect(voiceRows.first?["transcript"]?["verdict"]?.string == "voice")

        let limited = await call(tools, "list_recordings", ["limit": .number(1)])
        #expect(limited.structured?["recordings"]?.array?.compactMap { $0["file"]?.string } == [am])
        let since = await call(tools, "list_recordings", ["since": .string(now.addingTimeInterval(-25 * 60).formatted(.iso8601))])
        #expect(since.structured?["recordings"]?.array?.compactMap { $0["file"]?.string } == [am, hiss])

        let transcript = await call(tools, "get_transcript", ["file": .string(clock)])
        #expect(!transcript.isError, "\(transcript.content)")
        #expect(transcript.structured?["verdict"]?.string == "voice")
        #expect(transcript.structured?["text"]?.string?.contains("traffic") == true)
        #expect(transcript.structured?["words"]?.array?.isEmpty == false)
        let missing = await call(tools, "get_transcript", ["file": .string("nope.flac")])
        #expect(missing.isError)

        let found = await call(tools, "search_transcripts", ["query": .string("dust traffic")])
        #expect(!found.isError, "\(found.content)")
        #expect(found.structured?["results"]?.array?.compactMap { $0["file"]?.string } == [clock])
        let blank = await call(tools, "search_transcripts", ["query": .string("  ")])
        #expect(blank.isError)
    }
}
