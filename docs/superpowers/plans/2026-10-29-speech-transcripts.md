# Speech Transcripts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transcribe each finished audio recording through Whisper on OpenRouter, label it Voice or Possible noise, show word-timed text under the player waveform, and let a search field fade every recording that doesn't match.

**Architecture:**
- A new `Transcription` library target holds the pure parts:
  - the response model and the classifier, which guards against invented text;
  - audio prep (decode, downsample to 16 kHz, chunk, WAV);
  - the OpenRouter client, behind an injectable transport;
  - the sidecar store, the index and search.
- The app adds:
  - a Keychain-backed key store;
  - a `@MainActor @Observable` `TranscriptionQueue` with retries;
  - wiring from `AppModel.appendToLog`, and the transcript index in `RecordingsLibrary`;
  - the UI: Settings section, menu item, header chip, timeline badges, transcript strip and search.

**Tech Stack:** Swift 6 (tools 6.0), SwiftUI, macOS 15, Foundation URLSession, AVFoundation, Security (Keychain), Swift Testing. No new packages.

**Spec:** `docs/superpowers/specs/2026-10-29-speech-transcripts-design.md`. Read it before any task. It is the authority, and this plan argues from it.

## Global Constraints

- Never delete, move or modify a recording file. Transcription only reads recordings and writes `<folder>/.subfloor/transcripts/<file>.json`.
- The API key never appears in logs, `print`, error messages, `SessionState`/UserDefaults, sidecars, test fixtures, git, or on screen. Only "Key saved ✓" or "No key".
- No test makes a network call or touches the real Keychain.
  - Tests inject `HTTPTransport`, the transcribe closure, and `MemoryAPIKeyStore`.
  - `AppModel`'s designated init defaults to `MemoryAPIKeyStore()`. Only the convenience `init()` passes `KeychainAPIKeyStore()`.
- Transcription work never runs on the DSP or audio threads, nor blocks the main actor. Audio prep and sidecar I/O run in `Task.detached`.
- Request facts:
  - endpoint `POST https://openrouter.ai/api/v1/audio/transcriptions`;
  - header `Authorization: Bearer <key>`;
  - JSON body `{"model","input_audio":{"data":<raw base64>,"format":"wav"},"response_format":"verbose_json","timestamp_granularities":["word","segment"],"language"?}`, with `language` omitted when Auto-detect;
  - request timeout 90 s.
- Default model `openai/whisper-large-v3`, priced at $0.000008 per second. Default language `en`.
- Classifier constants:
  - `no_speech_prob > 0.6` drops the segment;
  - `avg_logprob < -1.0` drops it;
  - `compression_ratio > 2.4` drops it;
  - Voice needs at least 3 kept words.
- Stock phrases (normalized): "thank you", "thanks for watching", "thank you for watching", "thank you so much for watching", "please subscribe", "subtitles by the amaraorg community", "you", "bye".
- Audio prep constants:
  - 16 kHz mono 16-bit PCM WAV;
  - chunks of at most 120 s;
  - each cut at the quietest 100 ms window in the last 15 s before the limit;
  - under 0.5 s → Possible noise, not sent;
  - all-zero → Possible noise, not sent.
- Queue constants:
  - at most 2 recordings in flight;
  - retries after 10 s, 60 s and 300 s, then failed;
  - 401/403 → blocked "OpenRouter rejected the key";
  - 402 → blocked "OpenRouter account is out of credit";
  - other 4xx → failed, no auto-retry;
  - 408, 429, 5xx and URLError → retry.
- Relaunch rule: queue audio recordings that have no sidecar, `seconds != nil`, `start` within the last 24 h, and `start >= enabledSince`.
- `SessionState` fields are optional and decoded with `decodeIfPresent`, like the existing ones.
- Keychain: generic password, service `app.subfloor.SubFloor.openrouter`, account `api-key`.
- Copy, exactly as written:
  - "Possible noise — no clear speech"
  - "Couldn't transcribe — <reason>"
  - "Transcribing…"
  - "Not transcribed"
  - "Recordings are sent to OpenRouter and the model's provider for transcription."
  - "Transcribe Recordings" (menu item)
  - "Transcribe N recordings (≈ $x.xx)"
- Match the surrounding code: doc comments on types and non-obvious members in the existing voice, `@MainActor @Observable` for app models, `Task.detached` for background work, Swift Testing `@Test`/`#expect`.

## Review Focus

1. **Whisper's invented text on noise.** "\*car engine noise\*", ".", empty replies and stock phrases must never come out Voice. Pinned by Task 1's fixture tests over all 7 real responses.
2. **Key leakage through errors.** A failed request's `TranscriptionError.message` and a sidecar's JSON must never contain the key. Pinned in Task 3 (`errorMessagesNeverContainKey`) and Task 4 (`sidecarNeverContainsKey`).
3. **Offline when a recording ends, or the app quit mid-job.** It must be picked up on the next launch, and the 237-recording backlog must not be. Pinned in Task 6 (`relaunchQueuesRecentOnly`).
4. **A recording longer than 120 s.** Word times must stay file-relative after chunking. Pinned in Task 2 (`longRecordingChunksAtQuietPoint`) and Task 3 (`chunkOffsetsShiftWords`).
5. **Search that is empty, all spaces, or matches nothing.** Empty or all-spaces must restore everything. Nothing matching fades everything, and the ◀ ▶ buttons are disabled. Pinned in Task 4 (`blankQueryIsNoFilter`) and Task 9 (`noMatchesDisablesStepping`).

---

### Task 1: Transcription target, response model and classifier

**Files:**
- Modify: `Package.swift`
  - Add `.target(name: "Transcription")`.
  - Add `"Transcription"` to the `SubFloor` executable's dependencies.
  - Add `.testTarget(name: "TranscriptionTests", dependencies: ["Transcription"], resources: [.copy("Fixtures")])`.
- Create: `Sources/Transcription/WhisperResponse.swift`, `Sources/Transcription/TranscriptClassifier.swift`
- Test: `Tests/TranscriptionTests/TranscriptClassifierTests.swift`. The fixtures already exist in `Tests/TranscriptionTests/Fixtures/`.

**Interfaces:**
- Produces:
  ```swift
  public struct WhisperResponse: Codable, Equatable, Sendable {
      public var text: String
      public var language: String?
      public var duration: Double?
      public var segments: [Segment]?
      public var words: [Word]?
      public var usage: Usage?
      public struct Segment: Codable, Equatable, Sendable {
          public var start: Double, end: Double, text: String
          public var avgLogprob: Double?, noSpeechProb: Double?, compressionRatio: Double?   // snake_case keys
      }
      public struct Word: Codable, Equatable, Sendable { public var word: String, start: Double, end: Double }
      public struct Usage: Codable, Equatable, Sendable { public var seconds: Double?, cost: Double? }
  }
  public struct TranscriptChunk: Codable, Equatable, Sendable { public var offsetSeconds: Double; public var response: WhisperResponse }
  public struct TranscriptWord: Codable, Equatable, Sendable { public var text: String; public var start: Double; public var end: Double }  // file-relative seconds, text trimmed of spaces
  public enum TranscriptVerdict: String, Codable, Sendable { case voice, possibleNoise }
  public struct ClassifiedTranscript: Equatable, Sendable { public var verdict: TranscriptVerdict; public var words: [TranscriptWord]; public var text: String }  // text = words joined by " "
  public enum TranscriptClassifier {
      public static let maxNoSpeechProb = 0.6, minAvgLogprob = -1.0, maxCompressionRatio = 2.4
      public static let minVoiceWords = 3
      public static let stockPhrases: Set<String>
      public static func normalize(_ s: String) -> String   // lowercased, punctuation and symbols removed, whitespace collapsed, trimmed
      public static func isAnnotation(_ s: String) -> Bool  // nothing left after removing *…*, […], (…) and punctuation
      public static func classify(_ chunks: [TranscriptChunk]) -> ClassifiedTranscript
  }
  ```
- Classification rules: segment drops and word keeps follow spec §2.
  - A missing signal skips its check.
  - Words are kept when their midpoint falls inside a kept segment of the same chunk, and their normalized text is non-empty and not an annotation.
  - Every time is shifted by `offsetSeconds`.
  - A chunk with segments but no `words` gets pseudo-words: each kept segment's whitespace-split text, spread evenly across its `start…end`.
  - Empty `chunks` → possibleNoise with no words.

- [ ] **Step 1: Write the failing tests.** Add a helper `fixture(_ name: String) -> WhisperResponse` that loads `Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")`. Then write these tests:
  - `voiceClipIsVoice`: `voice-clip-32s` → `.voice`. Words include "Dustmob,". The last word is not "sorry." (the −1.17 segment is dropped). Word count is 44.
  - `clockClipIsVoice`: `SubFloor_20261028_140122Z_11175000Hz_USB` → `.voice`, 27 words.
  - `borderlineClipIsVoice`: `SubFloor_20261027_200017Z_11175000Hz_USB` → `.voice`, text == "I see. This is All right. Hi. Monogram. Now.".
  - `noiseClipsArePossibleNoise`: the four files `…015603Z_10086000Hz_AM`, `…025305Z…`, `…031415Z…`, `…134251Z…` → `.possibleNoise`, each with 0 words.
  - `stockPhraseDropped`: a hand-built segment "Thank you for watching!" with logprob −0.2 → 0 words.
  - `missingSignalsSkipChecks`: a segment with nil logprob, no_speech and ratio, and text "this is kilo one two" with no `words` → `.voice`, 5 pseudo-words evenly spaced across the segment.
  - `chunkOffsetsShiftWords`: the voice clip as a chunk at `offsetSeconds: 120` → the first word's `start` ≈ 121.23.
  - `emptyIsPossibleNoise`: `classify([])` → `.possibleNoise`.
- [ ] **Step 2:** Run `swift test --filter TranscriptClassifierTests`. Expected: FAIL (no such module or types).
- [ ] **Step 3:** Implement both files per the Interfaces block.
- [ ] **Step 4:** Run `swift test --filter TranscriptClassifierTests`. Expected: all pass.
- [ ] **Step 5:** Commit with `feat(stt): Transcription target with Whisper response model and noise classifier`.

### Task 2: Audio prep

**Files:**
- Create: `Sources/Transcription/TranscriptionAudio.swift`
- Test: `Tests/TranscriptionTests/TranscriptionAudioTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct PreparedChunk: Equatable, Sendable { public var offsetSeconds: Double; public var seconds: Double; public var wav: Data }
  public enum PreparedAudio: Equatable, Sendable { case silent, tooShort(seconds: Double), chunks([PreparedChunk]) }
  public enum TranscriptionAudio {
      public static let sampleRate = 16_000.0, maxChunkSeconds = 120.0, cutSearchSeconds = 15.0
      public static let cutWindowSeconds = 0.1, minSendSeconds = 0.5
      public static func prepare(url: URL) throws -> PreparedAudio      // AVAudioFile + AVAudioConverter → 16 kHz mono Float, then prepare(samples:)
      public static func prepare(samples: [Float]) -> PreparedAudio     // samples already 16 kHz mono
      public static func wav(_ samples: ArraySlice<Float>) -> Data      // 44-byte RIFF header, PCM 16-bit mono 16 kHz, clamped
  }
  ```
- Rules:
  - Check in this order: all-zero → `.silent`; then duration < 0.5 s → `.tooShort`; otherwise chunks.
  - A cut falls at the start of the 100 ms window, stepped by 100 ms, with the lowest RMS in `[limit − 15 s, limit)`. The next chunk starts there.
  - Use the first window on ties.

- [ ] **Step 1: Write the failing tests:**
  - `wavHeaderIsPCM16Mono16k`: bytes 0–3 "RIFF", 8–11 "WAVE"; little-endian fields: channels 1, rate 16000, bits 16; data size == 2 × sample count; total length 44 + 2n.
  - `allZeroIsSilent`.
  - `shortIsTooShort`: 0.4 s of a tone → `.tooShort(seconds: 0.4)`.
  - `shortRecordingIsOneChunk`: 30 s → one chunk, offset 0, seconds 30.
  - `longRecordingChunksAtQuietPoint`: 200 s of a tone with a 100 ms zero gap at 112.0 s → 2 chunks. The first is 112.0 s long; the second has offset 112.0 and length 88.0.
  - `noQuietPointStillCuts`: 250 s of an unbroken tone → 3 chunks, each ≤ 120 s, and offsets plus lengths cover 0…250 exactly.
  - `preparesRealFlac`: write 2 s of a 48 kHz tone to a temp `.flac` using `AVAudioFile` with FLAC settings, then `prepare(url:)` → one chunk with seconds ≈ 2.0 (±0.01).
- [ ] **Step 2:** Run `swift test --filter TranscriptionAudioTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test --filter TranscriptionAudioTests`. Expected: all pass.
- [ ] **Step 5:** Commit with `feat(stt): downsample, chunk and WAV-encode recordings for transcription`.

### Task 3: OpenRouter client and `.env` key parsing

**Files:**
- Create: `Sources/Transcription/OpenRouterTranscriber.swift`, `Sources/Transcription/EnvFile.swift`
- Test: `Tests/TranscriptionTests/OpenRouterTranscriberTests.swift`, `Tests/TranscriptionTests/EnvFileTests.swift`

**Interfaces:**
- Consumes: `PreparedAudio`/`PreparedChunk`/`TranscriptionAudio.prepare(url:)` from Task 2, and `WhisperResponse`/`TranscriptChunk` from Task 1.
- Produces:
  ```swift
  public protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }
  public struct URLSessionTransport: HTTPTransport { public init() }
  public enum TranscriptionError: Error, Equatable, Sendable {
      case rejectedKey, outOfCredit, badRequest(String), transient(String)
      public var message: String   // "OpenRouter rejected the key", "OpenRouter account is out of credit", or the reason
      public var isRetryable: Bool // transient only
  }
  public struct StoredTranscript: Codable, Equatable, Sendable {
      public var version: Int        // 1
      public var file: String, model: String, language: String?, createdAt: Date
      public var durationSeconds: Double, costUSD: Double?
      public var note: String?       // "silent" or "too short" when labelled without sending; else nil
      public var chunks: [TranscriptChunk]
  }
  public struct OpenRouterTranscriber: Sendable {
      public static let endpoint: URL               // https://openrouter.ai/api/v1/audio/transcriptions
      public static let defaultModel = "openai/whisper-large-v3"
      public static let requestTimeout: TimeInterval = 90
      public static let pricePerSecond: [String: Double]   // ["openai/whisper-large-v3": 0.000008]
      public init(apiKey: String, model: String, language: String?, transport: any HTTPTransport = URLSessionTransport())
      public func request(for chunk: PreparedChunk) throws -> URLRequest
      public func transcribe(_ chunk: PreparedChunk) async throws -> WhisperResponse
      public func transcribe(file: String, audio: PreparedAudio, now: Date) async throws -> StoredTranscript
  }
  public enum EnvFile { public static func openRouterKey(in contents: String) -> String? }
  ```
- Status mapping:
  - 200 → decode. A decode failure → `.badRequest("Unreadable reply from OpenRouter")`.
  - 401/403 → `.rejectedKey`.
  - 402 → `.outOfCredit`.
  - 408, 429 and 5xx → `.transient("OpenRouter is busy (HTTP n)")`.
  - Other 4xx → `.badRequest(body.error.message ?? "HTTP n")`.
  - A thrown `URLError` → `.transient(localizedDescription)`.
- Every reason string passes through a scrub that replaces any occurrence of the key with "•••".
- `transcribe(file:audio:now:)`:
  - Sends chunks in order.
  - `costUSD` is the sum of `usage.cost`, or nil when none was reported.
  - `durationSeconds` is the sum of chunk seconds.
  - `.silent` and `.tooShort` return without any request, with `note` set and `chunks: []`.
- `EnvFile` accepts `OPENROUTER=` or `OPENROUTER_API_KEY=` lines.
  - It handles an optional `export ` prefix, surrounding single or double quotes, and whitespace.
  - It skips `#` comments.
  - It returns the first non-empty value; empty values → nil.

- [ ] **Step 1: Write the failing tests.** Use a `StubTransport` that records requests and returns scripted `(status, body)` pairs or throws.
  - `requestShape`: POST to the endpoint; `Authorization` is `"Bearer k-test"`; `Content-Type` is `application/json`; `timeoutInterval` is 90. The body JSON has `model`, `input_audio.format == "wav"`, base64 `data` that decodes to the chunk's wav, `response_format == "verbose_json"`, `timestamp_granularities == ["word","segment"]`, and `language == "en"`. With `language: nil` there is no `language` key.
  - `decodesFixture`: a 200 carrying the `voice-clip-32s` fixture bytes → 46 words.
  - `statusMapping`: 401 → rejectedKey, 403 → rejectedKey, 402 → outOfCredit, 429 → transient, 503 → transient, 400 with `{"error":{"message":"bad format"}}` → `badRequest("bad format")`, `URLError(.notConnectedToInternet)` → transient.
  - `errorMessagesNeverContainKey`: with key "sk-or-secret", a 400 whose message echoes "sk-or-secret" → the `.message` contains "•••" and not "sk-or-secret".
  - `silentNeedsNoRequest`: `.silent` → zero requests, `note == "silent"`.
  - `chunksSentInOrderWithOffsets`: two chunks at offsets 0 and 112 → two requests, and the stored `chunks[1].offsetSeconds == 112`.
  - EnvFile tests: plain value; `export OPENROUTER="abc"` → abc; `OPENROUTER_API_KEY='abc'`; a comment line is skipped; `OPENROUTER=` → nil; a file with only another key → nil.
- [ ] **Step 2:** Run `swift test --filter "OpenRouterTranscriberTests|EnvFileTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the same command. Expected: pass.
- [ ] **Step 5:** Commit with `feat(stt): OpenRouter transcription client and .env key reader`.

### Task 4: Sidecar store, index and search matching

**Files:**
- Create: `Sources/Transcription/TranscriptStore.swift`, `Sources/Transcription/TranscriptIndex.swift`
- Test: `Tests/TranscriptionTests/TranscriptStoreTests.swift`, `Tests/TranscriptionTests/TranscriptIndexTests.swift`

**Interfaces:**
- Consumes: `StoredTranscript` (Task 3), `TranscriptClassifier` (Task 1).
- Produces:
  ```swift
  public enum TranscriptStore {
      public static func directory(in recordingsFolder: URL) -> URL            // <folder>/.subfloor/transcripts
      public static func url(for file: String, in recordingsFolder: URL) -> URL // <dir>/<file>.json
      public static func write(_ t: StoredTranscript, in recordingsFolder: URL) throws  // creates dir; .atomic
      public static func readAll(in recordingsFolder: URL) -> [String: StoredTranscript] // keyed by t.file; unreadable files skipped
  }
  public struct TranscriptSummary: Equatable, Sendable {
      public var verdict: TranscriptVerdict, words: [TranscriptWord], text: String
      public var searchText: String   // TranscriptSearch.normalize(text)
  }
  public struct TranscriptIndex: Equatable, Sendable {
      public init(_ stored: [String: StoredTranscript] = [:])
      public mutating func set(_ t: StoredTranscript)
      public func summary(_ file: String) -> TranscriptSummary?
      public func contains(_ file: String) -> Bool
      public func matches(_ file: String, terms: [String]) -> Bool   // false when no summary
  }
  public enum TranscriptSearch {
      public static func normalize(_ s: String) -> String   // case- and diacritic-folded, punctuation removed, whitespace collapsed
      public static func terms(_ query: String) -> [String] // normalized, split on whitespace; [] for blank
      public static func wordMatches(_ word: String, terms: [String]) -> Bool  // normalized word contains any term
  }
  ```
- Dates are encoded ISO-8601. The sidecar is pretty-printed with sorted keys, so diffs are readable.

- [ ] **Step 1: Write the failing tests:**
  - `writeThenReadAll`: round-trips 2 transcripts in a temp folder; the files are at `.subfloor/transcripts/<file>.json`.
  - `corruptSidecarSkipped`: a garbage `.json` beside a good one → readAll returns 1.
  - `sidecarNeverContainsKey`: a transcript written through `OpenRouterTranscriber` with a stub transport and key "sk-or-secret" → the file's bytes don't contain "sk-or-secret".
  - `indexClassifiesOnLoad`: the voice-clip fixture → `.voice`, and `searchText` contains "dustmob".
  - `multiTermAnd`: "dust traffic" matches the clock clip ("Dustmaw… traffic"); "dust banana" doesn't.
  - `diacriticAndCase`: "CAFÉ" matches the text "cafe".
  - `blankQueryIsNoFilter`: `terms("   ") == []`.
  - `unknownFileNeverMatches`.
- [ ] **Step 2:** Run `swift test --filter "TranscriptStoreTests|TranscriptIndexTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the same command. Expected: pass.
- [ ] **Step 5:** Commit with `feat(stt): transcript sidecars, index and search matching`.

### Task 5: Key store and transcription settings in AppModel

**Files:**
- Create: `Sources/SubFloor/App/APIKeyStore.swift`, `Sources/SubFloor/App/TranscriptionSettings.swift`
- Modify: `Sources/SubFloor/App/AppModel.swift`
  - Add the `SessionState` field `transcription: TranscriptionSettings?`.
  - Add the designated-init parameter `apiKeyStore: any APIKeyStore = MemoryAPIKeyStore()`.
  - The convenience `init()` passes `KeychainAPIKeyStore()`.
  - Add the model API below.
- Test: `Tests/SubFloorTests/TranscriptionSettingsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  protocol APIKeyStore: AnyObject { func load() -> String?; func save(_ key: String) throws; func remove() throws }
  final class KeychainAPIKeyStore: APIKeyStore   // SecItem generic password, service app.subfloor.SubFloor.openrouter, account api-key
  final class MemoryAPIKeyStore: APIKeyStore     // in the app target, used as the designated-init default and by tests
  struct TranscriptionSettings: Codable, Equatable, Sendable {
      var enabled = true
      var model = OpenRouterTranscriber.defaultModel
      var language: String? = "en"   // nil = Auto-detect
      var enabledSince: Date?
  }
  // AppModel
  var transcriptionSettings: TranscriptionSettings   // persisted in SessionState; turning enabled on sets enabledSince = now
  private(set) var hasAPIKey: Bool
  func saveAPIKey(_ key: String) throws   // trims; empty → remove
  func removeAPIKey() throws
  func importAPIKey(fromEnvFileAt url: URL) throws   // EnvFile.openRouterKey; nil → throws APIKeyImportError.noKey
  func toggleTranscription()
  var apiKey: String? { get }   // internal; cached at init from the store, never logged
  ```
- First launch with no stored settings: `enabledSince` = launch time.

- [ ] **Step 1: Write the failing tests** (AppModel with a throwaway `UserDefaults(suiteName: UUID)` and a `MemoryAPIKeyStore`, following `RecordingControlTests`):
  - `settingsPersist`: change the model and language, save the session, rebuild AppModel from the same defaults → the values return.
  - `oldSessionDecodes`: a session JSON without `transcription` → defaults, with `enabledSince` set.
  - `toggleOnStampsEnabledSince`: off, then on → `enabledSince` advances.
  - `keyNeverInSession`: after `saveAPIKey("sk-or-secret")`, the defaults' `"session"` data doesn't contain "sk-or-secret".
  - `importFromEnv`: a temp `.env` holding `OPENROUTER=sk-test` → `hasAPIKey` is true and the store holds "sk-test". A file without the key throws and leaves the key unchanged.
- [ ] **Step 2:** Run `swift test --filter TranscriptionSettingsTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. Keychain code: `SecItemAdd`, then `SecItemUpdate` on `errSecDuplicateItem`; `SecItemCopyMatching` with `kSecReturnData`; `SecItemDelete`, treating not-found as success. It has no unit test, by the Global Constraints.
- [ ] **Step 4:** Run `swift test --filter TranscriptionSettingsTests`. Expected: pass.
- [ ] **Step 5:** Commit with `feat(stt): OpenRouter key in the Keychain and transcription settings`.

### Task 6: TranscriptionQueue and wiring

**Files:**
- Create: `Sources/SubFloor/App/TranscriptionQueue.swift`
- Modify:
  - `Sources/SubFloor/App/RecordingsLibrary.swift`: add the transcript index, loaded in `reload()` off the main actor and reset in `setFolder`.
  - `Sources/SubFloor/App/AppModel.swift`: add the queue, enqueue from `appendToLog`, apply the relaunch rule, and add backlog entry points.
- Test: `Tests/SubFloorTests/TranscriptionQueueTests.swift`

**Interfaces:**
- Consumes: Tasks 3–5.
- Produces:
  ```swift
  typealias TranscribeFunction = @Sendable (_ file: String, _ url: URL, _ model: String, _ language: String?, _ apiKey: String) async throws -> StoredTranscript
  enum TranscriptionJobState: Equatable { case queued, running, failed(String) }
  @MainActor @Observable final class TranscriptionQueue {
      static let maxInFlight = 2
      static let retryDelays: [Duration] = [.seconds(10), .seconds(60), .seconds(300)]
      private(set) var states: [String: TranscriptionJobState]     // files with no transcript yet that the queue knows
      private(set) var blocked: TranscriptionError?                  // .rejectedKey or .outOfCredit; cleared when apiKey changes
      private(set) var backlogProgress: (done: Int, total: Int)?     // nil unless "Transcribe older" is running
      var apiKey: String?                                             // didSet: clears blocked and resumes
      var settings: TranscriptionSettings
      @ObservationIgnored var onTranscript: ((StoredTranscript, URL) -> Void)?   // (transcript, recordings folder)
      init(transcribe: @escaping TranscribeFunction = OpenRouterTranscriber.liveTranscribe,
           sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
      func enqueue(_ file: String, folder: URL)          // new recordings go to the front
      func enqueueBacklog(_ files: [String], folder: URL) // to the back; sets backlogProgress
      func stopBacklog()
      func dropQueued()                                  // turning off: queued removed, running finish
      func retry(_ file: String, folder: URL)
  }
  // RecordingsLibrary
  private(set) var transcripts: TranscriptIndex
  func didTranscribe(_ t: StoredTranscript, folder: URL)   // ignored unless folder == self.folder
  func recentUntranscribed(since: Date, now: Date) -> [String]   // audio, !inProgress, seconds != nil, start >= max(since, now − 24 h), no sidecar
  func untranscribed() -> [(file: String, seconds: Double?)]     // all audio, newest first
  // AppModel
  let transcription: TranscriptionQueue
  func transcribeOlderRecordings()
  func retryTranscription(_ file: String)
  var olderRecordingsEstimate: (count: Int, dollars: Double?) { get }
  ```
- `OpenRouterTranscriber.liveTranscribe` lives in the Transcription target as a `public static let` with the same closure shape, `(String, URL, String, String?, String) async throws -> StoredTranscript`, because the Transcription target cannot see the app's `TranscriptionSettings`. It runs `TranscriptionAudio.prepare(url:)` then `transcribe(file:audio:now:)` inside `Task.detached`.
- The queue writes the sidecar with `TranscriptStore.write` in a detached task before calling `onTranscript`. A write failure → `.failed("Couldn't save transcript: …")`.
- A file is enqueued only when `settings.enabled`, `apiKey != nil`, it is not already in `states` or the index, and `RecordingFileName.parse(file)?.isAudio == true`.
- AppModel calls the relaunch rule after the first `library.reload()` completes and when `enabled` goes on.

- [ ] **Step 1: Write the failing tests.** Use a scripted `TranscribeFunction` (a counter and a per-file result list) and a `sleep` that records durations and returns at once.
  - `enqueueTranscribesAndIndexes`: AppModel with a key and a temp recordings folder. Log a `.recording` entry for `SubFloor_20261029_120000Z_11175000Hz_USB.flac`, then await → the sidecar exists, `library.transcripts.summary(file)?.verdict == .voice` (stub returns the voice-clip fixture), and `states[file] == nil`.
  - `offOrNoKeyQueuesNothing`.
  - `iqFileNeverQueued`: a `.wav` IQ name (`…_IQ.wav`, per `RecordingFileName`) is not queued.
  - `atMostTwoInFlight`: 5 files with a stub that suspends → never more than 2 running at once.
  - `transientRetriesThenFails`: always `.transient("x")` → 4 attempts; sleeps == [10 s, 60 s, 300 s]; final state `.failed("x")`.
  - `rejectedKeyBlocksAll`: the first job → `.rejectedKey`. `blocked == .rejectedKey`, and other queued jobs aren't attempted. Setting `apiKey` resumes them.
  - `badRequestNoRetry`: `.badRequest("bad")` → 1 attempt, `.failed("bad")`.
  - `turningOffDropsQueued`: the running job finishes; queued states are removed.
  - `relaunchQueuesRecentOnly`: catalog of 3 recordings: one 2 h old with no sidecar, one 2 h old with a sidecar, one 3 days old with no sidecar. `enabledSince` is 1 week ago → only the first is queued.
  - `backlogProgressAndStop`: backlog of 3 → progress goes 0/3, 1/3 and so on; `stopBacklog` after the first leaves `backlogProgress == nil` and stops the rest.
  - `folderChangeDiscardsIndexing`: a job finishes after `setFolder` → the sidecar is written in the old folder and not added to the new index.
- [ ] **Step 2:** Run `swift test --filter TranscriptionQueueTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test --filter "TranscriptionQueueTests|RecordingsLibraryTests|RecordingControlTests|AutoRecordControlTests"`. Expected: all pass.
- [ ] **Step 5:** Commit with `feat(stt): transcription queue with retries, wired to finished recordings`.

### Task 7: Settings section, menu item and header chip

**Files:**
- Modify: `Sources/SubFloor/UI/SettingsView.swift`, `Sources/SubFloor/App/SubFloorApp.swift`, `Sources/SubFloor/UI/Recordings/RecordingsWindow.swift` (header chip only)
- Create: `Sources/SubFloor/UI/TranscriptionSection.swift`
- Test: `Tests/SubFloorTests/TranscriptionUITests.swift`

**Interfaces:**
- Consumes: the AppModel API from Tasks 5 and 6.
- Produces: `enum TranscriptionFormat { static func olderButton(count: Int, dollars: Double?) -> String; static func keyStatus(hasKey: Bool) -> String }`.
  - Button text: "Transcribe 237 recordings (≈ $0.05)". When dollars is nil: "Transcribe 237 recordings". When count is 0: "All recordings transcribed".
  - Key status: "Key saved ✓" or "No key".
- Settings → "Transcription" section, after "Recording", in the spec §6 order:
  - `Toggle("Transcribe recordings")`;
  - a SecureField with Save, Remove, and "Import from .env…" (`NSOpenPanel`, `.showsHiddenFiles = true`);
  - the key status;
  - the `blocked?.message` in red when set;
  - a model TextField;
  - a language Picker (English `en` or Auto-detect `nil`);
  - the privacy note copy;
  - the older-recordings button. While running it shows "n of N" and a Stop button.
- Menu: a "Transcribe Recordings" toggle in the menu that holds the Auto-record items, with no shortcut.
- Header chip: a compact toggle styled like the player's `SkipSilenceChip`, labelled "Transcribe", with a tooltip giving the key status or the blocked message.

- [ ] **Step 1: Write the failing tests:** `olderButtonCopy` covering the 3 cases (count 237 with $0.05; nil dollars; count 0) and `keyStatusCopy`.
- [ ] **Step 2:** Run `swift test --filter TranscriptionUITests`. Expected: FAIL.
- [ ] **Step 3:** Implement the format and the views.
- [ ] **Step 4:** Run `swift test --filter TranscriptionUITests && swift build`. Expected: pass, and it builds.
- [ ] **Step 5:** Commit with `feat(stt): Transcription settings, menu toggle and Recordings header chip`.

### Task 8: Timeline badges and the transcript strip

**Files:**
- Modify:
  - `Sources/SubFloor/UI/Recordings/TimelineView.swift`: add `TimelineLayout` inputs `marks: [String: TranscriptMark] = [:]` and `dimmed: Set<String> = []`; badges and dimming in `MarkerPaint`; a context menu.
  - `Sources/SubFloor/UI/Recordings/RecordingsWindow.swift`: compute `marks` and pass them.
  - `Sources/SubFloor/UI/Recordings/PlayerPanel.swift`: insert `TranscriptStrip` between `PlayerWaveform` and `PlayerControls`.
- Create: `Sources/SubFloor/UI/Recordings/TranscriptStrip.swift`
- Test: `Tests/SubFloorTests/TranscriptStripTests.swift`, plus additions to `Tests/SubFloorTests/RecordingsUITests.swift`

**Interfaces:**
- Consumes: `library.transcripts`, `transcription.states`, `WaveformZoom.visibleRange(duration:playhead:)`.
- Produces:
  ```swift
  enum TranscriptMark: Equatable { case voice, possibleNoise, failed(String) }
  enum TranscriptMarks { @MainActor static func marks(index: TranscriptIndex, states: [String: TranscriptionJobState]) -> [String: TranscriptMark] }
  struct PlacedWord: Equatable { var index: Int; var x: CGFloat; var line: Int }   // line 0 or 1
  enum TranscriptStripLayout {
      static let gap: CGFloat = 6
      static func place(_ words: [TranscriptWord], visible: ClosedRange<Double>, width: CGFloat,
                        measure: (String) -> CGFloat) -> [PlacedWord]
  }
  struct TranscriptStrip: View   // inputs: summary, mark/state, player position & duration, zoom, search terms, onSeek, onTranscribe
  ```
- `MarkerPaint` badge:
  - `badgeRect(rect)` = 4.5 pt square at `(rect.maxX − 4.5, rect.minY − 6.5)`. If `rect.width < 12`, x is `rect.minX + 6`, so it never covers the unheard dot.
  - Voice: a filled dot in green 0x4ddb78.
  - Possible noise: a 1 pt stroked grey ring.
  - Failed: a filled orange dot.
  - A dimmed marker draws at opacity 0.2, overriding the heard opacity.
- Hover text: a `· voice`, `· possible noise` or `· couldn't transcribe: <reason>` suffix in `DayTimelineView.hoverText`. It gains a `mark` parameter with default nil.
- Context menu on a marker under the pointer: "Transcribe", or "Transcribe Again" when a transcript exists. It calls `model.retryTranscription(file)`.
- Strip:
  - Height is 2 lines of 11 pt text.
  - The current word (start ≤ position < end) is `.primary`; others are `.secondary`.
  - Search-matching words get a green 0x4ddb78 background at 0.35 opacity.
  - Clicking a word calls `player.seek(to: word.start)`.
  - The empty states use the exact copy from the Global Constraints. "Not transcribed" has a "Transcribe" button, disabled without a key.
  - `.help` gives the full kept text.
  - Accessibility: the strip is an element labelled "Transcript" whose value is the kept text.

- [ ] **Step 1: Write the failing tests:**
  - `placeSpreadsWords`: words at 0, 1 and 2 s, visible 0…10, width 1000, each 40 pt wide → x = 0, 100, 200, all on line 0.
  - `placeOverlapGoesToLine1ThenHides`: words at 0, 0.1 and 0.2 s with width 40 → lines 0, 1, then hidden (2 placed).
  - `placeSkipsOffscreen`: visible 5…10 → a word at 3 s is absent.
  - `marksMerge`: index voice/noise plus a state `.failed("x")` → 3 marks; `.queued` and `.running` → no mark.
  - In RecordingsUITests: `layoutCarriesMarks`, where two layouts differing only in `marks` are unequal (keeps the `.equatable()` canvas honest); and `hoverTextNamesVerdict`.
- [ ] **Step 2:** Run `swift test --filter "TranscriptStripTests|RecordingsUITests"`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test --filter "TranscriptStripTests|RecordingsUITests|RecordingPlayerTests" && swift build`. Expected: pass.
- [ ] **Step 5:** Commit with `feat(stt): green transcript badges on the timeline and word-timed text under the waveform`.

### Task 9: Search field, fading and stepping across days

**Files:**
- Modify: `Sources/SubFloor/UI/Recordings/RecordingsWindow.swift` (header field, ⌘F, Esc, count, ◀ ▶, `dimmed`, search terms passed to the strip)
- Create: `Sources/SubFloor/UI/Recordings/RecordingsSearch.swift`
- Test: `Tests/SubFloorTests/RecordingsSearchTests.swift`

**Interfaces:**
- Consumes: `TranscriptSearch.terms`, `TranscriptIndex.matches`, `RecordingsCatalog`, and Task 8's `dimmed` input.
- Produces:
  ```swift
  struct RecordingsSearch: Equatable {
      let terms: [String]
      init(query: String)
      var isActive: Bool { !terms.isEmpty }
      func matches(catalog: RecordingsCatalog, index: TranscriptIndex) -> [CatalogRecording]   // listed, not in progress, sorted by start
      func dimmed(_ recordings: [CatalogRecording], index: TranscriptIndex) -> Set<String>     // empty when inactive
      static func step(_ matches: [CatalogRecording], from current: CatalogRecording?, forward: Bool) -> CatalogRecording?  // wraps around; nil when empty
  }
  ```
  `RecordingsCatalog` may need a public `allRecordings` (every listed recording, all days). Add it there with a test in `Tests/RecordingTests/RecordingsCatalogTests.swift`.
- Header:
  - A `TextField` with a magnifier glyph, placeholder "Search transcripts", before Show in Finder.
  - "N matches" appears only when active.
  - ◀ ▶ buttons are disabled when there are no matches.
  - Return = ▶. Esc clears the field. ⌘F focuses it.
  - Stepping sets `day` to the match's UTC day and calls `select`.

- [ ] **Step 1: Write the failing tests** (a hand-built catalog across 2 days plus an index):
  - `matchesAcrossDays`: "dust" → 2 matches on different days, sorted.
  - `dimmedOnlyWhenActive`: query "" → empty set; query "dust" → the non-matching and untranscribed files.
  - `stepWraps`: forward from the last → first; backward from the first → last; from nil → first or last.
  - `noMatchesDisablesStepping`: `step([], …) == nil`, and the dimmed set contains every recording.
  - `allRecordingsListsEveryDay` in RecordingsCatalogTests.
- [ ] **Step 2:** Run `swift test --filter "RecordingsSearchTests|RecordingsCatalogTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `swift test --filter "RecordingsSearchTests|RecordingsCatalogTests|RecordingsUITests" && swift build`. Expected: pass.
- [ ] **Step 5:** Commit with `feat(stt): search transcripts from the Recordings header, fading what does not match`.

### Task 10: README and full verification

**Files:**
- Modify: `README.md`. Add a feature row "Transcripts", and a short "Transcription" setup paragraph covering:
  - the key via Settings → Import from .env…;
  - the cost (~3 cents per hour of audio with Whisper Large V3);
  - the privacy note;
  - the Keychain prompt once per local build.

- [ ] **Step 1:** Edit the README to match the existing feature-table voice.
- [ ] **Step 2:** Run `swift build -c release 2>&1 | tail -3 && swift test 2>&1 | tail -5`. Expected: the build succeeds and all tests pass.
- [ ] **Step 3:** Commit with `docs(stt): README for transcripts and search`.
