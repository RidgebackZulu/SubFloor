import Foundation
import Recording
import SubFloorCore
import Testing
import Transcription
@testable import SubFloor

/// Holds callers until it is opened. Opening it lets every waiter, and every later caller, through.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let pass = lock.withLock {
                if isOpen { return true }
                waiters.append(c)
                return false
            }
            if pass { c.resume() }
        }
    }

    func open() {
        let held = lock.withLock {
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        held.forEach { $0.resume() }
    }
}

/// A scripted `TranscribeFunction`. Each file answers from its own list, one result per attempt (the last
/// repeats), or `fallback`. A gate set for a file holds that file's calls until it opens. Never touches the
/// network: a voice answer is the saved 32 s voice clip reply.
final class ScriptedTranscriber: @unchecked Sendable {
    enum Answer { case voice, error(TranscriptionError) }
    private let lock = NSLock()
    private var script: [String: [Answer]] = [:]
    private var gates: [String: TestGate] = [:]
    private var _calls: [String] = []
    private var _keys: [String] = []
    private var current = 0, _peak = 0
    var fallback: Answer = .voice
    /// Keys that OpenRouter would reject with 401.
    var rejected: Set<String> = []

    var calls: [String] { lock.withLock { _calls } }
    var keys: [String] { lock.withLock { _keys } }
    var running: Int { lock.withLock { current } }
    var peak: Int { lock.withLock { _peak } }

    func answer(_ file: String, _ answers: [Answer]) { lock.withLock { script[file] = answers } }
    @discardableResult
    func hold(_ file: String) -> TestGate {
        let gate = TestGate()
        lock.withLock { gates[file] = gate }
        return gate
    }

    var function: TranscribeFunction {
        { [self] file, _, model, language, key in try await run(file, model: model, language: language, key: key) }
    }

    private func run(_ file: String, model: String, language: String?, key: String) async throws -> StoredTranscript {
        let (answer, gate): (Answer, TestGate?) = lock.withLock {
            _calls.append(file)
            _keys.append(key)
            current += 1
            _peak = max(_peak, current)
            var list = script[file] ?? []
            let a = list.first ?? fallback
            if list.count > 1 { list.removeFirst(); script[file] = list }
            return (rejected.contains(key) ? .error(.rejectedKey) : a, gates[file])
        }
        await gate?.wait()
        lock.withLock { current -= 1 }
        switch answer {
        case .error(let e): throw e
        case .voice:
            let reply = try JSONDecoder().decode(WhisperResponse.self, from: try Data(contentsOf: Self.voiceFixture))
            return StoredTranscript(file: file, model: model, language: language, createdAt: Date(), durationSeconds: 32,
                                    costUSD: reply.usage?.cost, note: nil, chunks: [TranscriptChunk(offsetSeconds: 0, response: reply)])
        }
    }

    /// The Transcription tests' saved reply for the 32 s voice clip.
    static let voiceFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TranscriptionTests/Fixtures/voice-clip-32s.json")
}

/// The delays the queue asked to sleep; each returns at once, so no test waits real seconds.
final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [Duration] = []
    var durations: [Duration] { lock.withLock { _durations } }
    var function: @Sendable (Duration) async throws -> Void { { [self] d in lock.withLock { _durations.append(d) } } }
}

/// The transcription queue and its wiring: finished recordings are queued, sent at most two at a time,
/// retried, blocked by a bad key, saved as sidecars and indexed. The transcribe function is scripted and
/// keys are fake; nothing reaches the network or the Keychain.
@MainActor
@Suite(.serialized)
struct TranscriptionQueueTests {
    private func tempFolder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorQueueTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An audio recording's file name for a start time.
    private func name(_ start: Date, ext: String = "flac", label: String = "USB") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "SubFloor_\(f.string(from: start))Z_11175000Hz_\(label).\(ext)"
    }

    private func finished(_ file: String, start: Date = Date(), seconds: Double = 30) -> RecordingLogEntry {
        .recording(file: file, start: start, seconds: seconds, frequencyHz: 11_175_000, mode: "USB", auto: true)
    }

    /// A model whose recordings folder is a fresh temp folder, already read once.
    private func makeModel(_ stub: ScriptedTranscriber, key: String? = "sk-test") async -> (AppModel, URL) {
        let dir = tempFolder()
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: UserDefaults(suiteName: UUID().uuidString)!,
                         apiKeyStore: MemoryAPIKeyStore(key: key), transcribe: stub.function)
        let folder = dir.appendingPathComponent("rec", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        m.recording.folderPath = folder.path
        await m.library.reload()
        return (m, m.library.folder)
    }

    private func makeQueue(_ stub: ScriptedTranscriber, sleeps: SleepLog = SleepLog()) -> TranscriptionQueue {
        let q = TranscriptionQueue(transcribe: stub.function, sleep: sleeps.function)
        q.settings = TranscriptionSettings(enabledSince: Date())
        q.apiKey = "sk-test"
        return q
    }

    /// Waits (in real time, briefly) until `condition` holds, or records an issue after 5 s.
    private func until(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { Issue.record("timed out waiting for \(what)"); return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func sidecarExists(_ file: String, in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: TranscriptStore.url(for: file, in: folder).path)
    }

    @Test func enqueueTranscribesAndIndexes() async throws {
        let stub = ScriptedTranscriber()
        let (m, folder) = await makeModel(stub)
        defer { m.shutdown() }
        let file = "SubFloor_20261029_120000Z_11175000Hz_USB.flac"
        m.appendToLog([finished(file)])
        #expect(m.transcription.states[file] != nil)
        await m.transcription.waitUntilIdle()
        #expect(sidecarExists(file, in: folder))
        #expect(m.library.transcripts.summary(file)?.verdict == .voice)
        #expect(m.transcription.states[file] == nil)
        #expect(stub.calls == [file])
        #expect(stub.keys == ["sk-test"])
        // Logged again (a log line read twice): already transcribed, so not sent again.
        m.appendToLog([finished(file)])
        await m.transcription.waitUntilIdle()
        #expect(stub.calls == [file])
    }

    @Test func offOrNoKeyQueuesNothing() async throws {
        let stub = ScriptedTranscriber()
        let (noKey, _) = await makeModel(stub, key: nil)
        defer { noKey.shutdown() }
        noKey.appendToLog([finished("SubFloor_20261029_120000Z_11175000Hz_USB.flac")])
        #expect(noKey.transcription.states.isEmpty)

        let (off, _) = await makeModel(stub)
        defer { off.shutdown() }
        off.transcriptionSettings.enabled = false
        off.appendToLog([finished("SubFloor_20261029_120100Z_11175000Hz_USB.flac")])
        #expect(off.transcription.states.isEmpty)
        await off.transcription.waitUntilIdle()
        #expect(stub.calls.isEmpty)
    }

    @Test func iqFileNeverQueued() async throws {
        let stub = ScriptedTranscriber()
        let q = makeQueue(stub)
        let folder = tempFolder()
        q.enqueue("SubFloor_20261029_120000Z_11175000Hz_IQ.wav", folder: folder)
        q.enqueue("notes.txt", folder: folder)
        q.enqueueBacklog(["SubFloor_20261029_120000Z_11175000Hz_IQ.wav"], folder: folder)
        #expect(q.states.isEmpty)
        #expect(q.backlogProgress == nil)
        await q.waitUntilIdle()
        #expect(stub.calls.isEmpty)
    }

    @Test func atMostTwoInFlight() async throws {
        let stub = ScriptedTranscriber()
        let q = makeQueue(stub)
        let folder = tempFolder()
        let files = (0..<5).map { name(Date(timeIntervalSince1970: 1_792_000_000 + Double($0) * 60)) }
        let gates = files.map { stub.hold($0) }
        for file in files { q.enqueue(file, folder: folder) }
        await until("two running") { stub.running == 2 }
        try await Task.sleep(for: .milliseconds(50))   // a third would have started by now
        #expect(stub.running == 2)
        #expect(q.states.values.filter { $0 == .running }.count == 2)
        #expect(q.states.values.filter { $0 == .queued }.count == 3)
        gates.forEach { $0.open() }
        await q.waitUntilIdle()
        #expect(stub.peak == 2)
        #expect(Set(stub.calls) == Set(files))
        #expect(stub.calls.count == 5)
        #expect(q.states.isEmpty)
        #expect(files.allSatisfy { sidecarExists($0, in: folder) })
    }

    @Test func transientRetriesThenFails() async throws {
        let stub = ScriptedTranscriber()
        stub.fallback = .error(.transient("x"))
        let sleeps = SleepLog()
        let q = makeQueue(stub, sleeps: sleeps)
        let file = "SubFloor_20261029_120000Z_11175000Hz_USB.flac"
        q.enqueue(file, folder: tempFolder())
        await q.waitUntilIdle()
        #expect(stub.calls.count == 4)
        #expect(sleeps.durations == [.seconds(10), .seconds(60), .seconds(300)])
        #expect(TranscriptionQueue.retryDelays == [.seconds(10), .seconds(60), .seconds(300)])
        #expect(q.states[file] == .failed("x"))
        #expect(q.blocked == nil)
    }

    @Test func transientThenSuccess() async throws {
        let stub = ScriptedTranscriber()
        let file = "SubFloor_20261029_120000Z_11175000Hz_USB.flac"
        stub.answer(file, [.error(.transient("busy")), .voice])
        let sleeps = SleepLog()
        let q = makeQueue(stub, sleeps: sleeps)
        let folder = tempFolder()
        q.enqueue(file, folder: folder)
        await q.waitUntilIdle()
        #expect(stub.calls.count == 2)
        #expect(sleeps.durations == [.seconds(10)])
        #expect(q.states[file] == nil)
        #expect(sidecarExists(file, in: folder))
    }

    @Test func rejectedKeyBlocksAll() async throws {
        let stub = ScriptedTranscriber()
        stub.rejected = ["sk-bad"]
        let q = makeQueue(stub)
        q.apiKey = "sk-bad"
        let folder = tempFolder()
        var landed: [String] = []
        q.onTranscript = { t, _ in landed.append(t.file) }
        let files = (0..<3).map { name(Date(timeIntervalSince1970: 1_792_000_000 + Double($0) * 60)) }
        for file in files { q.enqueue(file, folder: folder) }
        await q.waitUntilIdle()
        #expect(q.blocked == .rejectedKey)
        #expect(stub.calls.count == 2)   // the two sent at once; the third is never tried
        #expect(files.allSatisfy { q.states[$0] == .queued })   // none failed: each is retried with a new key
        // New work waits too.
        let later = name(Date(timeIntervalSince1970: 1_792_100_000))
        q.enqueue(later, folder: folder)
        await q.waitUntilIdle()
        #expect(stub.calls.count == 2)
        #expect(q.states[later] == .queued)

        q.apiKey = "sk-good"
        #expect(q.blocked == nil)
        await q.waitUntilIdle()
        #expect(q.states.isEmpty)
        #expect(Set(landed) == Set(files + [later]))
        #expect(stub.calls.count == 6)
        #expect(stub.keys.suffix(4).allSatisfy { $0 == "sk-good" })
    }

    @Test func outOfCreditBlocksAndSameKeyResumes() async throws {
        let stub = ScriptedTranscriber()
        let file = "SubFloor_20261029_120000Z_11175000Hz_USB.flac"
        stub.answer(file, [.error(.outOfCredit), .voice])
        let q = makeQueue(stub)
        q.enqueue(file, folder: tempFolder())
        await q.waitUntilIdle()
        #expect(q.blocked == .outOfCredit)
        #expect(q.states[file] == .queued)
        q.apiKey = "sk-test"   // the same key saved again (after topping up): try again
        #expect(q.blocked == nil)
        await q.waitUntilIdle()
        #expect(q.states[file] == nil)
        #expect(stub.calls.count == 2)
    }

    @Test func badRequestNoRetry() async throws {
        let stub = ScriptedTranscriber()
        let file = "SubFloor_20261029_120000Z_11175000Hz_USB.flac"
        stub.answer(file, [.error(.badRequest("bad")), .voice])
        let sleeps = SleepLog()
        let q = makeQueue(stub, sleeps: sleeps)
        let folder = tempFolder()
        q.enqueue(file, folder: folder)
        await q.waitUntilIdle()
        #expect(stub.calls.count == 1)
        #expect(sleeps.durations.isEmpty)
        #expect(q.states[file] == .failed("bad"))
        // Enqueueing it again does nothing: the queue already knows it.
        q.enqueue(file, folder: folder)
        await q.waitUntilIdle()
        #expect(stub.calls.count == 1)
        // Retry (the marker's Transcribe) sends it again.
        q.retry(file, folder: folder)
        await q.waitUntilIdle()
        #expect(stub.calls.count == 2)
        #expect(q.states[file] == nil)
        #expect(sidecarExists(file, in: folder))
    }

    @Test func sidecarWriteFailureFails() async throws {
        let stub = ScriptedTranscriber()
        let q = makeQueue(stub)
        // A "folder" that is a plain file: the sidecar directory cannot be made inside it.
        let notAFolder = tempFolder().appendingPathComponent("plain-file")
        FileManager.default.createFile(atPath: notAFolder.path, contents: Data())
        var landed = 0
        q.onTranscript = { _, _ in landed += 1 }
        let file = "SubFloor_20261029_120000Z_11175000Hz_USB.flac"
        q.enqueue(file, folder: notAFolder)
        await q.waitUntilIdle()
        guard case .failed(let reason) = q.states[file] else { Issue.record("expected failed, got \(String(describing: q.states[file]))"); return }
        #expect(reason.hasPrefix("Couldn't save transcript: "))
        #expect(landed == 0)
    }

    @Test func turningOffDropsQueued() async throws {
        let stub = ScriptedTranscriber()
        let (m, folder) = await makeModel(stub)
        defer { m.shutdown() }
        let files = (0..<4).map { name(Date(timeIntervalSince1970: 1_792_000_000 + Double($0) * 60)) }
        let gates = files.map { stub.hold($0) }
        m.appendToLog(files.map { finished($0) })
        await until("two running") { stub.running == 2 }
        #expect(m.transcription.states.count == 4)
        m.transcriptionSettings.enabled = false
        #expect(m.transcription.states.count == 2)
        #expect(m.transcription.states.values.allSatisfy { $0 == .running })
        gates.forEach { $0.open() }
        await m.transcription.waitUntilIdle()
        #expect(stub.calls.count == 2)   // the running ones finished; the queued ones were never sent
        #expect(m.transcription.states.isEmpty)
        #expect(stub.calls.allSatisfy { sidecarExists($0, in: folder) && m.library.transcripts.contains($0) })
    }

    @Test func relaunchQueuesRecentOnly() async throws {
        let stub = ScriptedTranscriber()
        let (m, folder) = await makeModel(stub)
        defer { m.shutdown() }
        let now = Date()
        let recent = name(now.addingTimeInterval(-2 * 3600))
        let recentDone = name(now.addingTimeInterval(-2 * 3600 + 60))
        let old = name(now.addingTimeInterval(-3 * 86_400))
        let starts = [recent: now.addingTimeInterval(-2 * 3600), recentDone: now.addingTimeInterval(-2 * 3600 + 60),
                      old: now.addingTimeInterval(-3 * 86_400)]
        for (file, start) in starts {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(file).path, contents: Data())
            try RecordingLog(folder: folder).append([finished(file, start: start)])
        }
        // An IQ capture from the same hour is never queued.
        let iq = name(now.addingTimeInterval(-3600), ext: "wav", label: "IQ")
        FileManager.default.createFile(atPath: folder.appendingPathComponent(iq).path, contents: Data())
        try TranscriptStore.write(StoredTranscript(file: recentDone, model: "m", language: "en", createdAt: now, durationSeconds: 30,
                                                   costUSD: nil, note: "silent", chunks: []), in: folder)
        await m.library.reload()
        #expect(m.library.transcripts.contains(recentDone))

        // Turned on only an hour ago: the 2 h old recording predates it.
        m.transcriptionSettings.enabledSince = now.addingTimeInterval(-3600)
        m.queueRecentRecordings(now: now)
        await m.transcription.waitUntilIdle()
        #expect(stub.calls.isEmpty)

        m.transcriptionSettings.enabledSince = now.addingTimeInterval(-7 * 86_400)
        m.queueRecentRecordings(now: now)
        await m.transcription.waitUntilIdle()
        #expect(stub.calls == [recent])
        #expect(m.library.transcripts.contains(recent))
        #expect(m.library.recentUntranscribed(since: now.addingTimeInterval(-7 * 86_400), now: now).isEmpty)
    }

    @Test func savingAKeyQueuesTodaysRecordings() async throws {
        let stub = ScriptedTranscriber()
        let (m, folder) = await makeModel(stub, key: nil)
        defer { m.shutdown() }
        // Made earlier today while there was no key; transcription has been on since long before.
        let start = Date().addingTimeInterval(-3 * 3600)
        let file = name(start)
        FileManager.default.createFile(atPath: folder.appendingPathComponent(file).path, contents: Data())
        try RecordingLog(folder: folder).append([finished(file, start: start)])
        await m.library.reload()
        m.transcriptionSettings.enabledSince = Date().addingTimeInterval(-7 * 86_400)
        m.appendToLog([finished(file, start: start)])
        #expect(m.transcription.states.isEmpty)

        try m.saveAPIKey("sk-test")
        await m.transcription.waitUntilIdle()
        #expect(stub.calls == [file])
        #expect(sidecarExists(file, in: folder))
    }

    @Test func importingAKeyQueuesTodaysRecordings() async throws {
        let stub = ScriptedTranscriber()
        let (m, folder) = await makeModel(stub, key: nil)
        defer { m.shutdown() }
        let start = Date().addingTimeInterval(-3600)
        let file = name(start)
        FileManager.default.createFile(atPath: folder.appendingPathComponent(file).path, contents: Data())
        try RecordingLog(folder: folder).append([finished(file, start: start)])
        await m.library.reload()
        m.transcriptionSettings.enabledSince = Date().addingTimeInterval(-7 * 86_400)
        let env = tempFolder().appendingPathComponent(".env")
        try "OPENROUTER_API_KEY=sk-test\n".write(to: env, atomically: true, encoding: .utf8)
        try m.importAPIKey(fromEnvFileAt: env)
        await m.transcription.waitUntilIdle()
        #expect(stub.calls == [file])
    }

    @Test func emptyQueueKeyCountsAsNoKey() async throws {
        let stub = ScriptedTranscriber()
        let q = makeQueue(stub)
        q.apiKey = ""
        #expect(q.apiKey == nil)
        q.enqueue("SubFloor_20261029_120000Z_11175000Hz_USB.flac", folder: tempFolder())
        #expect(q.states.isEmpty)
    }

    @Test func turningOnQueuesRecent() async throws {
        let stub = ScriptedTranscriber()
        let (m, folder) = await makeModel(stub)
        defer { m.shutdown() }
        m.transcriptionSettings.enabled = false
        // Made while it was off, a minute ago.
        let file = name(Date().addingTimeInterval(-60))
        FileManager.default.createFile(atPath: folder.appendingPathComponent(file).path, contents: Data())
        try RecordingLog(folder: folder).append([finished(file, start: Date().addingTimeInterval(-60))])
        await m.library.reload()
        try await Task.sleep(for: .milliseconds(5))
        m.transcriptionSettings.enabled = true   // stamps enabledSince now: the recording predates it
        await m.transcription.waitUntilIdle()
        #expect(stub.calls.isEmpty)
    }

    @Test func backlogProgressAndStop() async throws {
        let stub = ScriptedTranscriber()
        let q = makeQueue(stub)
        let folder = tempFolder()
        let files = (0..<3).map { name(Date(timeIntervalSince1970: 1_792_000_000 - Double($0) * 60)) }   // newest first
        let gates = Dictionary(uniqueKeysWithValues: files.map { ($0, stub.hold($0)) })
        // Stopped as the first one lands, before its slot goes to the third.
        var atFirst: String?
        q.onTranscript = { t, _ in
            guard t.file == files[0] else { return }
            atFirst = q.backlogProgress.map { "\($0.done)/\($0.total)" }
            q.stopBacklog()
        }
        q.enqueueBacklog(files, folder: folder)
        #expect(q.backlogProgress?.done == 0 && q.backlogProgress?.total == 3)
        await until("two running") { stub.running == 2 }
        #expect(Set(stub.calls) == [files[0], files[1]])   // the first two in the order given
        #expect(q.states[files[2]] == .queued)
        gates[files[0]]!.open()
        await until("first landed") { atFirst != nil }
        #expect(atFirst == "1/3")
        #expect(q.backlogProgress == nil)
        #expect(q.states[files[2]] == nil)   // dropped
        #expect(q.states[files[1]] == .running)   // finishes
        gates.values.forEach { $0.open() }
        await q.waitUntilIdle()
        #expect(Set(stub.calls) == [files[0], files[1]])
        #expect(stub.calls.count == 2)
        #expect(q.backlogProgress == nil)
        #expect(q.states.isEmpty)

        // A full run counts every one, then clears.
        var seen: [String] = []
        q.onTranscript = { _, _ in seen.append(q.backlogProgress.map { "\($0.done)/\($0.total)" } ?? "-") }
        let more = (3..<6).map { name(Date(timeIntervalSince1970: 1_792_000_000 - Double($0) * 60)) }
        q.enqueueBacklog(more, folder: folder)
        #expect(q.backlogProgress?.done == 0 && q.backlogProgress?.total == 3)
        await q.waitUntilIdle()
        #expect(seen == ["1/3", "2/3", "-"])
        #expect(q.backlogProgress == nil)
    }

    @Test func stoppedBacklogJobIsNotRetried() async throws {
        let stub = ScriptedTranscriber()
        let sleeps = SleepLog()
        let q = makeQueue(stub, sleeps: sleeps)
        let file = "SubFloor_20261029_120000Z_11175000Hz_USB.flac"
        stub.answer(file, [.error(.transient("x")), .voice])
        let gate = stub.hold(file)
        q.enqueueBacklog([file], folder: tempFolder())
        await until("running") { stub.running == 1 }
        q.stopBacklog()
        gate.open()
        await q.waitUntilIdle()
        #expect(stub.calls == [file])
        #expect(sleeps.durations.isEmpty)
        #expect(q.states[file] == nil)
    }

    @Test func olderRecordingsEstimateAndBacklog() async throws {
        let stub = ScriptedTranscriber()
        let (m, folder) = await makeModel(stub)
        defer { m.shutdown() }
        let base = Date(timeIntervalSince1970: 1_792_000_000)
        let files = (0..<3).map { name(base.addingTimeInterval(Double($0) * 60)) }
        for (i, file) in files.enumerated() {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(file).path, contents: Data())
            try RecordingLog(folder: folder).append([finished(file, start: base.addingTimeInterval(Double(i) * 60), seconds: Double(i + 1) * 100)])
        }
        try TranscriptStore.write(StoredTranscript(file: files[2], model: "m", language: "en", createdAt: base, durationSeconds: 300,
                                                   costUSD: nil, note: "silent", chunks: []), in: folder)
        await m.library.reload()
        #expect(m.library.untranscribed().map(\.file) == [files[1], files[0]])   // newest first
        let estimate = m.olderRecordingsEstimate
        #expect(estimate.count == 2)
        #expect(abs((estimate.dollars ?? 0) - 300 * 0.000008) < 1e-12)
        m.transcriptionSettings.model = "someone/else"
        #expect(m.olderRecordingsEstimate.dollars == nil)
        #expect(m.olderRecordingsEstimate.count == 2)

        m.transcribeOlderRecordings()
        #expect(m.transcription.backlogProgress?.total == 2)
        await m.transcription.waitUntilIdle()
        #expect(Set(stub.calls) == [files[0], files[1]])
        #expect(m.olderRecordingsEstimate.count == 0)

        // Transcribe Again on a transcribed recording sends it again.
        m.retryTranscription(files[2])
        await m.transcription.waitUntilIdle()
        #expect(stub.calls.filter { $0 == files[2] }.count == 1)
    }

    @Test func folderChangeDiscardsIndexing() async throws {
        let stub = ScriptedTranscriber()
        let (m, folderA) = await makeModel(stub)
        defer { m.shutdown() }
        let file = "SubFloor_20261029_120000Z_11175000Hz_USB.flac"
        let gate = stub.hold(file)
        m.appendToLog([finished(file)])
        await until("running") { stub.running == 1 }
        let folderB = tempFolder()
        m.recording.folderPath = folderB.path
        #expect(m.library.folder.standardizedFileURL == folderB.standardizedFileURL)
        gate.open()
        await m.transcription.waitUntilIdle()
        #expect(sidecarExists(file, in: folderA))
        #expect(!sidecarExists(file, in: folderB))
        #expect(!m.library.transcripts.contains(file))
        await m.library.reload()
        #expect(!m.library.transcripts.contains(file))
        // Back to the first folder: its sidecars are read in again.
        m.recording.folderPath = folderA.path
        await m.library.reload()
        #expect(m.library.transcripts.contains(file))
    }
}
