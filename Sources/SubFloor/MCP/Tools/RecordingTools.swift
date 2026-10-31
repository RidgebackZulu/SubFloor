import DSPCore
import Foundation
import Recording
import Synchronization
import SubFloorCore
import Transcription

/// A recording an agent started, and the task that stops it at `stopsAt` (`start_recording`).
@MainActor
final class AgentRecording {
    let kind: StreamKind
    /// The agent that started it ("name version").
    let client: String
    /// `AppModel.recordingStarts[kind]` once it had started: a later start, the owner's, is another recording.
    let number: Int
    /// Read by the task at every wake, so a second `start_recording` moves it.
    var stopsAt: Date
    var task: Task<Void, Never>?

    init(kind: StreamKind, client: String, number: Int, stopsAt: Date) {
        self.kind = kind
        self.client = client
        self.number = number
        self.stopsAt = stopsAt
    }
}

/// Listening, recording, Auto, and the recordings and their transcripts. Agents never delete a recording, every
/// recording an agent starts stops by itself, and the owner always wins: what the owner started or changed is
/// left as it is.
extension SubFloorTools {
    static var recordingTools: [SubFloorTool] {
        [
            SubFloorTool("listen", title: "Listen", readOnly: false, locksRadio: false, description: """
                Hear the current frequency for seconds (2–60, default 15) and report what came through: the \
                signal level over that time (level_dbfs min, median, max, sampled every 200 ms), how long the \
                squelch was open (squelch_open_seconds; all of it when the squelch is off) and, when the owner has \
                Transcribe Recordings on and a key saved, a Whisper transcript of the audio before the squelch \
                {text, verdict: "voice" or "possible_noise", words (how many kept)} (about $0.0001 per 15 s; \
                transcribe: false skips it, and note says why there is none). keep: true saves the clip as a \
                recording in the owner's Recordings and returns its file. Needs the radio running. If the owner \
                or another agent retunes, changes mode or stops the radio meanwhile, it stops early and returns \
                {interrupted} saying what changed and by whom, e.g. "retuned to 7.2 MHz by the owner". Returns {seconds, level_dbfs, squelch_open_seconds, transcribed, transcript?, note?, \
                file?}.
                """, properties: [
                    "seconds": .schema("number", "How long to listen, 2–60 s (default 15)."),
                    "transcribe": .schema("boolean", "false: no transcript (default true, if the owner allows)."),
                    "keep": .schema("boolean", "true: save the clip as a recording (default false)."),
                ]) { t, args, _ in try await t.listen(args) },

            SubFloorTool("start_recording", title: "Start recording", readOnly: false, description: """
                Record the radio: kind "audio" (what is heard, before the squelch fades it), "iq" (the whole \
                capture) or "both", starting the pre-roll ago. It stops by itself after max_minutes (default 30, \
                at most 240), or earlier if the owner stops it or the disk is nearly full (under 100 MB free, \
                when it is also refused); a second call moves the time limit of your own recording. A recording \
                the owner started is left alone. Needs the radio running. \
                Returns {started, stops_at, note?}.
                """, properties: [
                    "kind": .enumSchema(["audio", "iq", "both"], "What to record."),
                    "max_minutes": .schema("number", "Stop after this many minutes (default 30, at most 240)."),
                ], required: ["kind"]) { t, args, client in try t.startRecording(args, client: client) },

            SubFloorTool("stop_recording", title: "Stop recording", readOnly: false, description: """
                Stop the recordings agents started: kind "audio", "iq" or "both" (default). The owner's own \
                recordings keep running. Returns {stopped, note?}.
                """, properties: [
                    "kind": .enumSchema(["audio", "iq", "both"], "Which (default both)."),
                ]) { t, args, _ in try t.stopRecording(args) },

            SubFloorTool("set_auto_record", title: "Set Auto-record", readOnly: false, description: """
                Turn Auto-record on or off. Auto records each transmission that opens the squelch, so it needs the \
                squelch on (set_squelch); it records only while the radio runs on the RSP1B, and waits otherwise \
                (auto_state says why). With on: true it turns itself off after minutes (default 60, at most 720), \
                even across a relaunch, unless the owner turns it off and on meanwhile; if the owner had it on \
                already it stays on with no limit. on: false turns off only an agent's Auto: the owner's is left on \
                (an error says so). Returns {on, auto_state, off_at?, note?}.
                """, properties: [
                    "on": .schema("boolean", "Auto on or off."),
                    "minutes": .schema("number", "With on: turn Auto off after this many minutes (default 60, at most 720)."),
                ], required: ["on"]) { t, args, _ in try t.setAutoRecord(args) },

            SubFloorTool("list_recordings", title: "List recordings", readOnly: true, description: """
                The audio recordings in the owner's Recordings, newest first: file, start, seconds (null while \
                unknown), frequency_hz, mode, auto, heard, in_progress and transcript (null, or {verdict, words, \
                excerpt}). Optionally only those started since and/or until (ISO 8601 times), within tolerance_hz \
                (default 5000) of frequency, or with a "voice" transcript (voice_only). At most limit (default 50, \
                up to 500). Returns {recordings}.
                """, properties: [
                    "since": .schema("string", "ISO 8601 time, e.g. \"2026-10-31T14:00:00Z\"."),
                    "until": .schema("string", "ISO 8601 time."),
                    "frequency": .frequencySchema("Display Hz, or a string like \"11.175 MHz\"."),
                    "tolerance_hz": .schema("number", "How far from frequency (default 5000 Hz)."),
                    "voice_only": .schema("boolean", "Only recordings whose transcript is voice."),
                    "limit": .schema("integer", "At most this many (default 50, up to 500)."),
                ]) { t, args, _ in try await t.listRecordings(args) },

            SubFloorTool("get_transcript", title: "Get transcript", readOnly: true, description: """
                A recording's transcript: verdict ("voice" or "possible_noise"), text, and words {text, start, end} \
                (seconds into the recording), with the recording's start, frequency_hz and mode. file is a name \
                from list_recordings.
                """, properties: [
                    "file": .schema("string", "The recording's file name."),
                ], required: ["file"]) { t, args, _ in try t.transcript(args) },

            SubFloorTool("search_transcripts", title: "Search transcripts", readOnly: true, description: """
                The recordings whose transcript holds every word of query (case, accents and punctuation \
                ignored), newest first, at most limit (default 20, up to 200): file, start, frequency_hz, mode, \
                verdict and excerpt. Returns {results}.
                """, properties: [
                    "query": .schema("string", "Words to find."),
                    "limit": .schema("integer", "At most this many (default 20, up to 200)."),
                ], required: ["query"]) { t, args, _ in try await t.searchTranscripts(args) },
        ]
    }

    // MARK: Listen

    static let listenSeconds: ClosedRange<Double> = 2...60
    /// How often `listen` samples the signal level and checks the tuning.
    static let listenPoll: Duration = .milliseconds(200)

    /// Why `listen` must stop, if the owner or an agent changed the radio from `start` since `since`.
    private func interruption(from start: RadioState, since: Date) -> String? {
        let now = radioState
        guard now != start else { return nil }
        let who = changedBy(now, since: since)
        if !now.running { return "the radio stopped by \(who)" }
        if now.vfoHz != start.vfoHz { return "retuned to \(FrequencyFormatter.short(now.vfoHz)) by \(who)" }
        return "mode changed to \(now.mode.label) by \(who)"
    }

    func listen(_ args: ToolArguments) async throws -> [String: JSONValue] {
        let seconds = try args.double("seconds", default: 15, in: Self.listenSeconds)
        let wantsTranscript = try args.bool("transcribe", default: true)
        let keep = try args.bool("keep", default: false)
        let m = model, tap = m.engine.audioTap
        // The radio lock only to start: after the changes queued before this call, and not in the way of those
        // that come while it listens, which interrupt it.
        let (initial, mark, start) = try await withRadio { () throws -> (RadioState, AudioTap.Mark, Date) in
            try requireRunning()
            return (radioState, tap.mark(), Date())
        }
        let vfo = initial.vfoHz, mode = initial.mode
        let end = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        var levels: [Float] = []
        while ContinuousClock.now < end {
            do { try await Task.sleep(for: min(Self.listenPoll, end - ContinuousClock.now)) } catch { break }
            if let why = interruption(from: initial, since: start) {
                return ["interrupted": .string(why), "seconds": .num(Self.tenths(Date().timeIntervalSince(start)))]
            }
            levels.append(m.signalDb)
        }
        try Task.checkCancellation()

        let samples = await offMain { tap.samples(since: mark) }
        let sorted = (levels.isEmpty ? [m.signalDb] : levels).sorted()
        var r: [String: JSONValue] = [
            "seconds": .num(Self.tenths(Double(samples.count) / tap.rate)),
            "level_dbfs": .object(["min": .db(sorted[0]), "median": .db(sorted[sorted.count / 2]),
                                   "max": .db(sorted[sorted.count - 1])]),
            "squelch_open_seconds": .num(Self.tenths(tap.openSeconds(since: mark))),
            "transcribed": .bool(false),
        ]

        var stored: StoredTranscript?
        let settings = m.transcriptionSettings
        if !wantsTranscript {
            r["note"] = .string("Not transcribed: transcribe was false.")
        } else if !settings.enabled {
            r["note"] = .string("Not transcribed: Transcribe Recordings is off in SubFloor's settings; only the owner can turn it on.")
        } else if let key = m.transcriptionKey {
            let name = RecordingNames.base(firstSample: start, frequencyHz: vfo, label: mode.label) + ".wav"
            do {
                stored = try await transcribe(samples, rate: tap.rate, file: name, settings: settings, key: key)
                if stored == nil { r["note"] = .string("Not transcribed: the audio was silent or under half a second.") }
            } catch let e as TranscriptionError {
                r["note"] = .string("Not transcribed: \(e.message).")
            } catch {
                r["note"] = .string("Not transcribed: \(error.localizedDescription)")
            }
            if let stored {
                let c = TranscriptClassifier.classify(stored.chunks)
                var transcript: [String: JSONValue] = ["text": .string(c.text), "verdict": .string(c.verdict.toolName),
                                                       "words": .number(Double(c.words.count))]
                if let cost = stored.costUSD { transcript["cost_usd"] = .num(cost) }
                r["transcript"] = .object(transcript)
                r["transcribed"] = .bool(true)
            }
        } else {
            r["note"] = .string("Not transcribed: no OpenRouter key is saved in SubFloor's settings; only the owner can add one.")
        }

        if keep {
            guard !samples.isEmpty else { throw ToolError("No audio came through to keep: is the radio running? Try listen again.") }
            r["file"] = .string(try await m.saveListenClip(samples, rate: tap.rate, start: start, frequencyHz: vfo,
                                                           mode: mode, transcript: stored))
        }
        return r
    }

    /// `samples` (at `rate`) through the model's transcribe function, as a 16 kHz WAV in a temporary file; nil
    /// when there is nothing worth sending.
    private func transcribe(_ samples: [Float], rate: Double, file: String, settings: TranscriptionSettings,
                            key: String) async throws -> StoredTranscript? {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloor-listen-\(UUID().uuidString).wav")
        let written = try await Task.detached(priority: .userInitiated) { () throws -> Bool in
            guard let wav = Self.transcriptionWAV(samples, rate: rate) else { return false }
            try wav.write(to: temp)
            return true
        }.value
        guard written else { return nil }
        defer { try? FileManager.default.removeItem(at: temp) }
        return try await model.transcribeFunction(file, temp, settings.model, settings.language, key)
    }

    /// The 16 kHz WAV transcription sends, or nil for audio that is silent or too short to send.
    nonisolated static func transcriptionWAV(_ samples: [Float], rate: Double) -> Data? {
        var resampler = FractionalResampler(inputRate: rate, outputRate: TranscriptionAudio.sampleRate)
        var out: [Float] = []
        out.reserveCapacity(Int(Double(samples.count) * TranscriptionAudio.sampleRate / rate) + 64)
        samples.withUnsafeBufferPointer { resampler.process($0, into: &out) }
        guard case .chunks = TranscriptionAudio.prepare(samples: out) else { return nil }
        return TranscriptionAudio.wav(out[...])
    }

    nonisolated static func tenths(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    // MARK: Recording

    static let maxRecordingMinutes: ClosedRange<Double> = 0.01...240
    static let autoMinutes: ClosedRange<Double> = 0.01...720

    /// "audio", "iq" or "both" (the default when `required` is false).
    static func streamKinds(_ args: ToolArguments, required: Bool) throws -> [StreamKind] {
        let choice = required ? try args.required("kind") { try args.choice($0, ["audio", "iq", "both"]) }
                              : try args.choice("kind", ["audio", "iq", "both"]) ?? "both"
        return choice == "both" ? StreamKind.allCases : [StreamKind(rawValue: choice)!]
    }

    func recorderStatus(_ kind: StreamKind) -> RecordingStatus {
        kind == .iq ? model.engine.iqRecorder.status : model.engine.audioRecorder.status
    }

    /// Whether `entry`'s recording is still being written: no later manual start has replaced it, and the
    /// recorder writes a manual recording.
    func isRunning(_ entry: AgentRecording) -> Bool {
        let s = recorderStatus(entry.kind)
        return model.recordingStarts[entry.kind] == entry.number && s.isRecording && !s.isAuto
    }

    func startRecording(_ args: ToolArguments, client: String) throws -> [String: JSONValue] {
        let kinds = try Self.streamKinds(args, required: true)
        let minutes = try args.double("max_minutes", default: 30, in: Self.maxRecordingMinutes)
        try requireRunning()
        let m = model
        guard !diskNearlyFull else {
            throw ToolError("The disk where recordings go is nearly full (under 100 MB free): nothing was recorded. "
                            + "Only the owner can free space.")
        }
        m.refreshRecordingStatus()
        let stopsAt = Date().addingTimeInterval(minutes * 60)
        var started: [JSONValue] = [], notes: [String] = []
        for kind in kinds {
            if let entry = agentRecordings[kind], isRunning(entry) {
                entry.stopsAt = stopsAt
                started.append(.string(kind.rawValue))
                notes.append("The \(kind.label) recording was already yours: it now stops at the new time.")
                continue
            }
            if m.isRecording(kind) {
                notes.append("The owner is already recording \(kind.label): it is left as it is, with no time limit.")
                continue
            }
            m.startRecording(kind)
            guard m.isRecording(kind) else {
                throw ToolError("The \(kind.label) recording did not start: \(m.banner?.message ?? "no reason given").")
            }
            watch(AgentRecording(kind: kind, client: client, number: m.recordingStarts[kind] ?? 0, stopsAt: stopsAt))
            started.append(.string(kind.rawValue))
        }
        var r: [String: JSONValue] = ["started": .array(started), "stops_at": .time(stopsAt)]
        if !notes.isEmpty { r["note"] = .string(notes.joined(separator: " ")) }
        return r
    }

    /// Whether less than Auto's floor (`AppModel.autoOffDiskBytes`) is free where recordings go.
    var diskNearlyFull: Bool {
        model.recordingsFreeSpace.map { $0 < AppModel.autoOffDiskBytes } ?? false
    }

    /// Follows `entry` until it stops for another reason, or stops it at its time or when the disk is nearly
    /// full (checked every `recordingDiskCheckInterval`).
    private func watch(_ entry: AgentRecording) {
        agentRecordings[entry.kind]?.task?.cancel()
        agentRecordings[entry.kind] = entry
        entry.task = Task { [weak self] in
            var diskChecked = ContinuousClock.now, diskFull = false
            while true {
                let left = entry.stopsAt.timeIntervalSinceNow
                if left <= 0 { break }
                do { try await Task.sleep(for: .milliseconds(Int(min(left, 0.25) * 1000) + 1)) } catch { return }
                guard let self, self.isRunning(entry) else { self?.forget(entry); return }
                if ContinuousClock.now - diskChecked >= self.recordingDiskCheckInterval {
                    diskChecked = .now
                    if self.diskNearlyFull { diskFull = true; break }
                }
            }
            guard let self else { return }
            self.forget(entry)
            guard self.isRunning(entry) else { return }
            if diskFull {
                self.log?.add(.error, client: entry.client,
                              "Stopped the agent's \(entry.kind.label) recording: less than 100 MB free where recordings go")
                self.model.show(Banner(kind: .error,
                                       message: "Stopped \(entry.client)'s recording: the disk is nearly full."))
            }
            self.model.refreshRecordingStatus()
            self.model.stopRecording(entry.kind)
            // Show the stop as soon as the file is finished, rather than at the next status poll.
            for _ in 0..<100 where self.recorderStatus(entry.kind).isRecording {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
            }
            self.model.refreshRecordingStatus()
        }
    }

    private func forget(_ entry: AgentRecording) {
        if agentRecordings[entry.kind] === entry { agentRecordings[entry.kind] = nil }
    }

    func stopRecording(_ args: ToolArguments) throws -> [String: JSONValue] {
        let kinds = try Self.streamKinds(args, required: false)
        let m = model
        m.refreshRecordingStatus()
        var stopped: [JSONValue] = [], notes: [String] = []
        for kind in kinds {
            if let entry = agentRecordings[kind], isRunning(entry) {
                entry.task?.cancel()
                forget(entry)
                m.stopRecording(kind)
                stopped.append(.string(kind.rawValue))
            } else if m.isRecording(kind) {
                notes.append("The \(kind.label) recording is the owner's: it keeps running.")
            }
        }
        var r: [String: JSONValue] = ["stopped": .array(stopped)]
        if !notes.isEmpty { r["note"] = .string(notes.joined(separator: " ")) }
        return r
    }

    // MARK: Auto

    func setAutoRecord(_ args: ToolArguments) throws -> [String: JSONValue] {
        let on = try args.required("on", args.bool)
        let minutes = try args.double("minutes", default: 60, in: Self.autoMinutes)
        let m = model
        func result(offAt: Date? = nil, note: String? = nil) -> [String: JSONValue] {
            var r: [String: JSONValue] = ["on": .bool(m.autoRecordEnabled), "auto_state": .string(m.autoRecordState.toolName)]
            if let offAt { r["off_at"] = .time(offAt) }
            var notes = [note].compactMap { $0 }
            switch m.autoRecordState {
            case .needsRadio: notes.append("Auto waits for the radio: call start_radio.")
            case .demoSource: notes.append("Auto does not record the demo signal: it waits for the RSP1B.")
            default: break
            }
            if !notes.isEmpty { r["note"] = .string(notes.joined(separator: " ")) }
            return r
        }
        // Auto with no time limit is the owner's: an agent neither turns it off nor puts a limit on it.
        let ownersAuto = m.autoRecordEnabled && m.autoRecordOffAt == nil
        guard on else {
            guard !ownersAuto else { throw ToolError("Auto was turned on by the owner: left on.") }
            m.autoRecordEnabled = false
            return result()
        }
        guard m.squelchEnabled else { throw ToolError("Turn the squelch on first (set_squelch).") }
        if ownersAuto { return result(note: "Auto was already on (the owner's): it stays on, with no time limit.") }
        let offAt = Date().addingTimeInterval(minutes * 60)
        m.turnOnAutoRecord(until: offAt)   // an agent's own Auto gets the new time
        return result(offAt: offAt)
    }

    // MARK: Recordings and transcripts

    /// An ISO 8601 time, with or without fractional seconds.
    static func time(_ args: ToolArguments, _ key: String) throws -> Date? {
        guard let s = try args.string(key) else { return nil }
        if let d = try? Date(s, strategy: .iso8601) { return d }
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) { return d }
        throw ToolError("\(key) must be an ISO 8601 time, like \"2026-10-31T14:00:00Z\".")
    }

    /// The first `limit` characters of `text`, with "…" when cut.
    nonisolated static func excerpt(_ text: String, limit: Int = 300) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    #if DEBUG
    /// `list_recordings` rows built on the main thread (tests: there must be none).
    nonisolated static let recordingRowsBuiltOnMain = Mutex(0)
    #endif

    nonisolated static func recordingJSON(_ r: CatalogRecording, _ summary: TranscriptSummary?) -> JSONValue {
        #if DEBUG
        if Thread.isMainThread { recordingRowsBuiltOnMain.withLock { $0 += 1 } }
        #endif
        return .object([
            "file": .string(r.file), "start": .time(r.start), "seconds": r.seconds.map { .num(tenths($0)) }.orNull,
            "frequency_hz": .hz(r.frequencyHz), "mode": .string(r.mode), "auto": .bool(r.auto), "heard": .bool(r.heard),
            "in_progress": .bool(r.inProgress),
            "transcript": summary.map {
                .object(["verdict": .string($0.verdict.toolName), "words": .number(Double($0.words.count)),
                         "excerpt": .string(excerpt($0.text))])
            }.orNull,
        ])
    }

    func listRecordings(_ args: ToolArguments) async throws -> [String: JSONValue] {
        let since = try Self.time(args, "since"), until = try Self.time(args, "until")
        let hz = try args.frequency("frequency")
        let tolerance = try args.double("tolerance_hz", default: 5_000, in: 0...1e10)
        let voiceOnly = try args.bool("voice_only", default: false)
        let limit = try args.int("limit", default: 50, in: 1...500)
        let catalog = model.library.catalog, index = model.library.transcripts
        // Built in full off the main actor: a lazy sequence returned from here would filter and build on it.
        let rows: [JSONValue] = await offMain {
            Array(catalog.allRecordings.reversed().lazy
                .filter { r in
                    if let since, r.start < since { return false }
                    if let until, r.start > until { return false }
                    if let hz, abs(r.frequencyHz - hz) > tolerance { return false }
                    return !voiceOnly || index.summary(r.file)?.verdict == .voice
                }
                .prefix(limit)
                .map { Self.recordingJSON($0, index.summary($0.file)) })
        }
        return ["recordings": .array(rows)]
    }

    func transcript(_ args: ToolArguments) throws -> [String: JSONValue] {
        let file = try args.required("file", args.string)
        let library = model.library
        guard let summary = library.transcripts.summary(file) else {
            if library.catalog.recording(file) == nil {
                throw ToolError("No recording is named \(file): list_recordings gives the file names.")
            }
            throw ToolError("\(file) has no transcript yet: list_recordings shows which recordings have one.")
        }
        var r: [String: JSONValue] = [
            "file": .string(file), "verdict": .string(summary.verdict.toolName), "text": .string(summary.text),
            "words": .array(summary.words.map {
                .object(["text": .string($0.text), "start": .num(Self.tenths($0.start)), "end": .num(Self.tenths($0.end))])
            }),
        ]
        if let rec = library.catalog.recording(file) {
            r["start"] = .time(rec.start)
            r["frequency_hz"] = .hz(rec.frequencyHz)
            r["mode"] = .string(rec.mode)
        }
        return r
    }

    func searchTranscripts(_ args: ToolArguments) async throws -> [String: JSONValue] {
        let query = try args.required("query", args.string)
        let limit = try args.int("limit", default: 20, in: 1...200)
        let terms = TranscriptSearch.terms(query)
        guard !terms.isEmpty else { throw ToolError("query needs at least one word to look for.") }
        let catalog = model.library.catalog, index = model.library.transcripts
        let results = await offMain {
            index.files.filter { index.matches($0, terms: terms) }
                .compactMap { catalog.recording($0) }
                .sorted { ($0.start, $0.file) > ($1.start, $1.file) }
                .prefix(limit)
                .map { r -> JSONValue in
                    let s = index.summary(r.file)
                    return .object(["file": .string(r.file), "start": .time(r.start), "frequency_hz": .hz(r.frequencyHz),
                                    "mode": .string(r.mode), "verdict": s.map { .string($0.verdict.toolName) }.orNull,
                                    "excerpt": .string(Self.excerpt(s?.text ?? ""))])
                }
        }
        return ["results": .array(Array(results))]
    }
}

extension TranscriptVerdict {
    /// The verdict as tools name it.
    var toolName: String {
        switch self {
        case .voice: "voice"
        case .possibleNoise: "possible_noise"
        }
    }
}
