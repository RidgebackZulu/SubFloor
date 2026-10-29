import Foundation
import Observation
import Recording
import Transcription

/// Turns one recording into a transcript: file name, its URL, model, language (nil for auto-detect), API key.
/// The app's is `OpenRouterTranscriber.liveTranscribe`; tests script one so nothing reaches the network.
typealias TranscribeFunction = @Sendable (_ file: String, _ url: URL, _ model: String, _ language: String?, _ apiKey: String) async throws -> StoredTranscript

/// Where a recording the queue knows about stands. A transcribed recording has no state: it is in the index.
enum TranscriptionJobState: Equatable {
    /// Waiting for a slot, for a retry delay to pass, or for a key OpenRouter accepts.
    case queued
    /// Being prepared and sent.
    case running
    /// Given up on, with the reason to show. Kept in memory only, so it is tried again on the next launch.
    case failed(String)
}

/// Sends finished recordings for transcription, at most `maxInFlight` at a time, and saves each transcript
/// beside its recording. New recordings go to the front of the line and the older-recordings backlog to the
/// back. A dropped connection or a busy server is retried after each of `retryDelays`, then the recording is
/// marked failed; a rejected key or an empty account blocks the whole queue until the key is saved again.
///
/// Nothing here runs on the DSP or audio threads, and nothing blocks the main actor: the transcribe function
/// does its own work off it, and the sidecar is written on a detached task. Failures are never written to
/// disk and never pop anything up; they are in `states` and `blocked` for the UI to show on demand.
@MainActor @Observable
final class TranscriptionQueue {
    static let maxInFlight = 2
    /// The waits before the second, third and fourth attempts after a transient failure.
    static let retryDelays: [Duration] = [.seconds(10), .seconds(60), .seconds(300)]

    /// The recordings with no transcript yet that the queue knows: queued, running or failed. Entries leave
    /// when their transcript is saved, or when they are dropped.
    private(set) var states: [String: TranscriptionJobState] = [:]
    /// `.rejectedKey` or `.outOfCredit` while the queue is stopped for it; nil otherwise.
    private(set) var blocked: TranscriptionError?
    /// How far "Transcribe older recordings" has got; nil unless it is running.
    private(set) var backlogProgress: (done: Int, total: Int)?
    /// The key requests are sent with; nil sends nothing, and an empty key counts as nil. Setting it, even to
    /// the same key, clears `blocked` and resumes: saving the key again is how the owner says "try again"
    /// after topping up the account. Not observed: no view shows the key, and the UI reads `hasAPIKey`.
    @ObservationIgnored var apiKey: String? {
        didSet {
            if apiKey?.isEmpty == true { apiKey = nil }
            blocked = nil
            pump()
        }
    }
    /// The model, the language, and whether recordings are queued at all. Turning `enabled` off does not drop
    /// what is queued by itself; `AppModel` calls `dropQueued` for that.
    var settings = TranscriptionSettings()
    /// Called with each saved transcript and the recordings folder it was saved in, after the sidecar is written.
    @ObservationIgnored var onTranscript: ((StoredTranscript, URL) -> Void)?
    /// Whether the current folder's index already has a transcript for a file; such a file is not queued
    /// again (except by `retry`). Set by `AppModel` to read the library's index.
    @ObservationIgnored var isTranscribed: (String) -> Bool = { _ in false }

    /// A recording to transcribe, and the folder it was in when it was queued: its sidecar goes there even if
    /// the folder setting changes meanwhile.
    private struct Job {
        /// Tells this job from a later one for the same file, so a stale retry timer wakes nothing.
        let id = UUID()
        let file: String
        let folder: URL
        /// The backlog run it belongs to, or nil for a new recording or a retry.
        let backlog: Int?
        /// Transient failures so far.
        var retries = 0
    }

    @ObservationIgnored private let transcribe: TranscribeFunction
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    /// Waiting for a slot, front first.
    @ObservationIgnored private var pending: [Job] = []
    /// Jobs sitting out a retry delay, by file. One that is dropped meanwhile is removed here and not resumed.
    @ObservationIgnored private var resting: [String: Job] = [:]
    @ObservationIgnored private var inFlight = 0
    /// Numbers backlog runs, so a job from a stopped run does not count towards a new one.
    @ObservationIgnored private var backlogRun = 0
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// `sleep` waits out the retry delays; tests pass one that returns at once.
    init(transcribe: @escaping TranscribeFunction = OpenRouterTranscriber.liveTranscribe,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.transcribe = transcribe
        self.sleep = sleep
    }

    /// Queues a finished recording at the front of the line. Nothing happens when transcription is off, there
    /// is no key, the file is not an audio recording, or the queue or the index already knows it.
    func enqueue(_ file: String, folder: URL) {
        guard accepts(file) else { return }
        states[file] = .queued
        pending.insert(Job(file: file, folder: folder, backlog: nil), at: 0)
        pump()
    }

    /// Queues older recordings at the back of the line, in the order given (newest first, as the library
    /// lists them), and counts them in `backlogProgress`. Files `enqueue` would refuse are left out.
    func enqueueBacklog(_ files: [String], folder: URL) {
        var seen: Set<String> = []
        let wanted = files.filter { accepts($0) && seen.insert($0).inserted }
        guard !wanted.isEmpty else { return }
        if backlogProgress == nil { backlogRun += 1 }
        for file in wanted {
            states[file] = .queued
            pending.append(Job(file: file, folder: folder, backlog: backlogRun))
        }
        backlogProgress = (backlogProgress?.done ?? 0, (backlogProgress?.total ?? 0) + wanted.count)
        pump()
    }

    /// Stops "Transcribe older recordings": its queued recordings are dropped; the ones being sent finish.
    func stopBacklog() {
        guard backlogProgress != nil else { return }
        backlogProgress = nil
        drop { $0.backlog == backlogRun }
    }

    /// Transcription was turned off: every queued recording is dropped, the backlog with them. The ones being
    /// sent finish.
    func dropQueued() {
        backlogProgress = nil
        drop { _ in true }
    }

    /// Sends a recording again: one that failed, or one already transcribed ("Transcribe again"). One that is
    /// queued or being sent already is left as it is.
    func retry(_ file: String, folder: URL) {
        guard settings.enabled, apiKey != nil, isAudio(file) else { return }
        switch states[file] {
        case .queued?, .running?: return
        case .failed?, nil: break
        }
        states[file] = .queued
        pending.insert(Job(file: file, folder: folder, backlog: nil), at: 0)
        pump()
    }

    /// Returns once nothing is being sent, waiting out a retry delay, or able to start: every job is done,
    /// failed, or held by `blocked` or a missing key. For tests.
    func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: Private

    private func accepts(_ file: String) -> Bool {
        settings.enabled && apiKey != nil && states[file] == nil && !isTranscribed(file) && isAudio(file)
    }

    private func isAudio(_ file: String) -> Bool { RecordingFileName.parse(file)?.isAudio == true }

    private var canStart: Bool { blocked == nil && apiKey != nil && settings.enabled }

    private var isIdle: Bool { inFlight == 0 && resting.isEmpty && (pending.isEmpty || !canStart) }

    /// Removes the queued and resting jobs that match; their states go with them.
    private func drop(where matches: (Job) -> Bool) {
        for job in pending where matches(job) { states[job.file] = nil }
        pending.removeAll(where: matches)
        for (file, job) in resting where matches(job) {
            resting[file] = nil
            states[file] = nil
        }
        settle()
    }

    /// Starts queued jobs while there is a free slot and nothing holds the queue.
    private func pump() {
        while canStart, inFlight < Self.maxInFlight, !pending.isEmpty, let key = apiKey {
            let job = pending.removeFirst()
            states[job.file] = .running
            inFlight += 1
            Task { await run(job, key: key) }
        }
        settle()
    }

    private func run(_ job: Job, key: String) async {
        let settings = self.settings
        let url = job.folder.appendingPathComponent(job.file)
        do {
            let t = try await transcribe(job.file, url, settings.model, settings.language, key)
            let folder = job.folder
            let saved = await Task.detached(priority: .utility) { () -> String? in
                do { try TranscriptStore.write(t, in: folder); return nil } catch { return error.localizedDescription }
            }.value
            if let failure = saved {
                finish(job, .failed("Couldn't save transcript: \(failure)"))
            } else {
                finish(job, nil)
                onTranscript?(t, folder)
            }
        } catch let error as TranscriptionError {
            switch error {
            case .rejectedKey, .outOfCredit:
                // Tried again, without counting, once the key is saved again. A key changed while this one
                // was being sent is not blocked by the old key's rejection.
                if key == apiKey { blocked = error }
                requeue(job)
            case .transient where job.retries < Self.retryDelays.count:
                rest(job, for: Self.retryDelays[job.retries])
            default:
                finish(job, .failed(error.message))
            }
        } catch {
            finish(job, .failed(error.localizedDescription))
        }
        inFlight -= 1
        pump()
    }

    /// Records how a job ended (no state once its transcript is saved, `.failed` otherwise) and counts it
    /// towards the backlog run it belongs to.
    private func finish(_ job: Job, _ outcome: TranscriptionJobState?) {
        states[job.file] = outcome
        countBacklog(job)
    }

    private func countBacklog(_ job: Job) {
        guard let run = job.backlog, run == backlogRun, let progress = backlogProgress else { return }
        let done = progress.done + 1
        backlogProgress = done >= progress.total ? nil : (done, progress.total)
    }

    /// False for a job that was being sent when transcription was turned off or its backlog run was stopped:
    /// it finishes, but is not tried again.
    private func stillWanted(_ job: Job) -> Bool {
        settings.enabled && (job.backlog == nil || (job.backlog == backlogRun && backlogProgress != nil))
    }

    /// Back to the front of the line, unless it is no longer wanted.
    private func requeue(_ job: Job) {
        guard stillWanted(job) else { states[job.file] = nil; return }
        states[job.file] = .queued
        pending.insert(job, at: 0)
    }

    /// Waits out a retry delay off the slot, then goes back to the front of the line. While the queue is
    /// blocked it waits there with the rest.
    private func rest(_ job: Job, for delay: Duration) {
        guard stillWanted(job) else { states[job.file] = nil; return }
        var job = job
        job.retries += 1
        states[job.file] = .queued
        resting[job.file] = job
        Task { [sleep] in
            try? await sleep(delay)
            guard resting[job.file]?.id == job.id else { return }   // dropped meanwhile
            resting[job.file] = nil
            pending.insert(job, at: 0)
            pump()
        }
    }

    /// Wakes `waitUntilIdle` callers once there is nothing left to do.
    private func settle() {
        guard isIdle, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }
}
