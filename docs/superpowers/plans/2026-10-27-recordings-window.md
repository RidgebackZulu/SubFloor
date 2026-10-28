# Recordings Window Implementation Plan (Part 2 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Recordings window, opened from a new Recordings button. It has:
- a UTC day timeline with one lane per frequency and mode;
- a marker for each recording and a row of ignored pops;
- a waveform player that scrubs with the mouse and keys;
- a red badge on the button counting unheard recordings, and a Clear button.

**Architecture:** The pure parts live in the `Recording` target and are unit-tested there:
- parsing recording file names;
- a `RecordingsCatalog` that merges the folder listing, the day logs and the live recording into days, lanes, pops and heard state;
- `WaveformPeaks`, a per-file peak cache.

The app gains two `@MainActor @Observable` objects, both owned by `AppModel`:
- `RecordingsLibrary` loads the catalog off the main actor and keeps it current.
- `RecordingPlayer` wraps `AVAudioPlayer` and mutes the live radio while it plays.

The window is SwiftUI: a `Canvas` timeline and a `Canvas` waveform.

**Tech Stack:** Swift 6, SwiftUI (`Window`, `Canvas`), AVFoundation (`AVAudioFile`, `AVAudioPlayer`), Swift Testing. No new targets or dependencies.

**Spec:** `docs/superpowers/specs/2026-10-26-auto-record-design.md`. This plan covers §4 (the Recordings window) and §5 (the player). It also covers the §4.4 heard rules and the §7 timeline model tests. Part 1 (merged first, PR RidgebackZulu/SubFloor#3) wrote the log this window reads. Part 3 (Dial scrub mode) gets its own plan; this plan leaves `RecordingPlayer.jump` and `move(jumps:)` ready for it.

## Global Constraints

- **Platform and style:** Swift 6 strict concurrency, macOS 15, Apple Silicon. Match the surrounding code: `///` comments that explain *why*, and Swift Testing (`@Suite`, `@Test`, `#expect`).
- **Days are UTC days.** The timeline runs 00–24 h UTC with hour ticks, labelled every 3 h. A recording belongs to the UTC day of its first sample.
- **The window never edits recordings.** It never edits, moves or deletes a recording, and never edits a log line. It writes only two things: `heard` log entries, and peak cache files in `<recordings folder>/.subfloor/peaks/`.
- **Exact copy:**
  - Menu item: `Recordings…` with ⌘⇧L.
  - Header buttons: `Today`, `Clear` and `Show in Finder`.
  - Lane titles: `11.175 MHz USB`.
  - Player clock: `07:48:12.4Z`.
  - Badge: hidden at 0, `99+` above 99.
- **Jump sizes:** 0.1 s, 0.5 s, 1 s, 5 s, 30 s, 5 min. The default is 1 s.
- **Lane palette,** cycled by lane index: amber `#ffb847`, cyan `#5cd6ff`, green `#4ddb78`, pink `#ff7ac8`, violet `#a98bff`, lime `#c6f06a`.
- **Window colours:** background `#0b0f15`, panels `#10151d`, text `#d8e1ec`, muted text `#6b7686`, now line `#ff5a5f`. Mockup: `.superpowers/brainstorm/65286-1793062814/content/day-timeline.html` (option B and the player). It is git-ignored, so read it from the main checkout if your worktree lacks it.
- **No blocking work on the main actor.** Folder scans, log reads, duration reads and peak computation run off the main actor. Peak computation is cancellable.
- **Heard rules (spec §4.4):**
  - A recording is unheard when the log has a `recording` or `autoStarted` entry for its file and no `heard` entry for it, in any day's log.
  - Files with no log entry are heard and manual. That covers files from before Part 1, and the later parts of a WAV recording that rolled.
  - A recording still in progress is never counted as unheard and cannot be played.

## Review Focus

1. **A selected or playing file is deleted in Finder.** Its marker disappears at the next folder refresh. The player unloads it and live audio comes back, with no crash and no stale badge. Test in Task 4.
2. **A recording crosses 00:00 UTC.** It appears only on its start day, with its marker clipped at the 24 h edge. Test in Task 1 (catalog) and Task 5 (geometry).
3. **Playback runs to the end of the file.** The player stops with the playhead at the end and live audio unmuted. Test in Task 4.
4. **A recording that can't be read** (a FLAC file cut short by a crash). Its marker still shows. Selecting it shows `Can't play this file`, the waveform shows nothing, and the window stays responsive. Test in Task 2 (peaks throw) and Task 4 (player load throws).
5. **The recordings folder is changed in Settings.** The catalog reloads from the new folder and the badge recounts. A player loaded from the old folder unloads. Test in Task 3.

---

### Task 1: File names, reading every log, and the catalog

**Files:**
- Create: `Sources/Recording/RecordingsCatalog.swift`
- Modify: `Sources/Recording/RecordingLog.swift` (add `allEntries()`)
- Test: `Tests/RecordingTests/RecordingsCatalogTests.swift`

**Interfaces:**
- Consumes: `RecordingLogEntry`, `RecordingLog` (Part 1); `RecordingNames.base` (the name shape `SubFloor_20261027_183219Z_11175000Hz_USB.flac`, with `_2`, `_3`… before the extension when a name is taken).
- Produces:
  ```swift
  public struct RecordingFileName: Equatable, Sendable {
      public let start: Date            // second resolution, UTC
      public let frequencyHz: Double
      public let label: String          // "USB", "AM", "IQ"…
      public let fileExtension: String  // "wav", "flac", "m4a"…
      /// nil unless the name is `SubFloor_yyyyMMdd_HHmmssZ_<int>Hz_<LABEL>[_<n>].<ext>`.
      public static func parse(_ name: String) -> RecordingFileName?
      /// An audio recording: wav, flac or m4a, and a label other than "IQ".
      public var isAudio: Bool
  }
  public struct LiveRecording: Equatable, Sendable {
      public var file: String, start: Date, seconds: Double, frequencyHz: Double, mode: String, auto: Bool
  }
  public struct CatalogRecording: Equatable, Sendable, Identifiable {
      public var id: String { file }
      public let file: String
      public var start: Date
      public var seconds: Double?       // nil: no log entry and not measured yet
      public var frequencyHz: Double
      public var mode: String
      public var auto: Bool
      public var heard: Bool
      public var inProgress: Bool
      public var laneID: String         // "11175000 USB"
  }
  public struct CatalogLane: Equatable, Sendable, Identifiable {
      public let id: String, frequencyHz: Double, mode: String, title: String
  }
  public struct CatalogPop: Equatable, Sendable { public let at: Date, seconds: Double, frequencyHz: Double, mode: String }
  public struct RecordingsCatalog: Equatable, Sendable {
      public init(files: [String] = [], entries: [RecordingLogEntry] = [], live: LiveRecording? = nil)
      public mutating func setFiles(_ files: [String])            // the folder listing, names only
      public mutating func apply(_ entries: [RecordingLogEntry])  // more log lines, in order written
      public mutating func setLive(_ live: LiveRecording?)
      public mutating func setMeasuredSeconds(_ seconds: Double, for file: String)
      public func recordings(onUTCDay day: Date) -> [CatalogRecording]   // sorted by start
      public func lanes(onUTCDay day: Date) -> [CatalogLane]              // sorted by frequency, then mode
      public func pops(onUTCDay day: Date) -> [CatalogPop]                // sorted by time
      public func recording(_ file: String) -> CatalogRecording?
      public var files: Set<String> { get }
      public var unheardFiles: [String] { get }                          // sorted
      public var unheardCount: Int { get }
      public static func laneTitle(frequencyHz: Double, mode: String) -> String
      public static func utcDayStart(_ date: Date) -> Date
  }
  extension RecordingLog {
      /// Every `*.jsonl` in `.subfloor/`, oldest day first; undecodable lines skipped; no folder → [].
      public func allEntries() throws -> [RecordingLogEntry]
  }
  ```
  `LiveRecording`, `CatalogRecording` and `CatalogPop` each get an explicit public memberwise `init`. Swift's synthesized one is internal, and the app and its tests construct these types.

The merge rules are in the tests below. A recording's start, frequency, mode and auto flag come from the first matching source:
1. its `recording` entry;
2. its `autoStarted` entry, with `seconds` nil;
3. the file name, with `auto` false.

Only names in the listing that parse as audio are recordings. The one exception is the live recording, which is included even before the listing shows it. Log entries for files not in the listing are ignored, so files deleted in Finder vanish.

- [ ] **Step 1: Write the failing tests**

  The tests build entries with the Part 1 cases and use `day(2026, 10, 27)` (UTC midnight) as a helper.

  ```swift
  @Test func parsesRecordingNames() {
      let n = RecordingFileName.parse("SubFloor_20261027_183219Z_11175000Hz_USB.flac")!
      #expect(n.start == utc(2026, 10, 27, 18, 32, 19)); #expect(n.frequencyHz == 11_175_000)
      #expect(n.label == "USB"); #expect(n.fileExtension == "flac"); #expect(n.isAudio)
      #expect(RecordingFileName.parse("SubFloor_20261027_183219Z_11175000Hz_USB_2.wav")?.label == "USB")
      #expect(RecordingFileName.parse("SubFloor_20261027_150938Z_11125000Hz_IQ.wav")?.isAudio == false)
      #expect(RecordingFileName.parse("notes.txt") == nil)
      #expect(RecordingFileName.parse("SubFloor_2026_bad.flac") == nil)
  }
  @Test func laneTitles() {
      #expect(RecordingsCatalog.laneTitle(frequencyHz: 11_175_000, mode: "USB") == "11.175 MHz USB")
      #expect(RecordingsCatalog.laneTitle(frequencyHz: 6_925_000, mode: "AM") == "6.925 MHz AM")
      #expect(RecordingsCatalog.laneTitle(frequencyHz: 7_000_000, mode: "LSB") == "7.000 MHz LSB")
      #expect(RecordingsCatalog.laneTitle(frequencyHz: 14_074_500, mode: "USB") == "14.0745 MHz USB")
  }
  @Test func logEntriesWinOverTheName()      // recording entry's ms start, seconds and auto: true are used
  @Test func autoStartedWithoutEndHasNoLength()   // seconds == nil, auto == true, unheard
  @Test func filesWithoutLogEntriesAreHeardAndManual()   // a pre-Part-1 file, and a rolled `_2` WAV part
  @Test func deletedFilesVanish()            // entries for a file not in setFiles(...) give no recording; unheardCount drops
  @Test func heardInALaterDaysLogCounts()    // a heard entry filed on 10-28 marks a 10-27 recording heard
  @Test func unheardCountsOnlyFinishedRecordings()   // live recording: inProgress, heard == false, not in unheardFiles
  @Test func liveRecordingAppearsBeforeTheListingDoes()   // setLive with a file not yet listed → recording on its day, seconds == live.seconds
  @Test func lanesPerFrequencyAndMode()      // 6.925 AM, 6.925 USB, 11.175 USB → three lanes sorted 6.925 AM, 6.925 USB, 11.175 USB
  @Test func popsByUTCDay()                  // a pop at 23:59:59.900Z on 10-27 is on 10-27, not 10-28
  @Test func recordingCrossingMidnightStaysOnItsStartDay()   // 23:30 start, 3600 s → on 10-27 only
  @Test func measuredSecondsFillLegacyLengths()   // setMeasuredSeconds(42, for:) → seconds == 42
  @Test func allEntriesReadsEveryDay()       // RecordingLog.append on two days, then allEntries() returns both, oldest day first
  ```
- [ ] **Step 2: Run them and see them fail**

  Run: `swift test --filter RecordingsCatalogTests`

  Expected: FAIL. `RecordingFileName` is not defined.
- [ ] **Step 3: Implement the types listed above in `Sources/Recording/RecordingsCatalog.swift`, and `allEntries()` beside `entries(forUTCDay:)`.**
  - Keep a dictionary per file for the log facts, a heard set and a pop list. `recordings(onUTCDay:)` computes from them on demand; a day holds at most a few hundred items.
  - **Lane title:** MHz with 3 decimals, or more when needed (up to 6), with trailing zeros trimmed down to 3. Then a space and the mode.
- [ ] **Step 4: Run them and see them pass**

  Run: `swift test --filter RecordingsCatalogTests`

  Expected: PASS.
- [ ] **Step 5: Commit**

  `git commit -m "feat(recordings): catalog of recordings, lanes, pops and heard state from the folder and the log"`

### Task 2: `WaveformPeaks`, computed off the main actor and cached

**Files:**
- Create: `Sources/Recording/WaveformPeaks.swift`
- Test: `Tests/RecordingTests/WaveformPeaksTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct WaveformPeaks: Equatable, Sendable {
      public static let binsPerSecond = 100          // 10 ms bins: a 0.1 s jump spans 10 bins
      public let sampleRate: Double
      public let frames: Int
      public let peaks: [UInt8]                       // max |sample| per bin, 255 = full scale
      public var duration: Double { get }             // frames / sampleRate
      /// The cached peaks for `audioFile` if the cache matches its size and modification date, else
      /// computed (and the cache written). Throws for an unreadable file; throws CancellationError
      /// promptly (checked every second of audio) when the calling task is cancelled.
      public static func load(audioFile: URL, cacheFolder: URL) async throws -> WaveformPeaks
  }
  ```
  - **Cache file:** `<cacheFolder>/<audio file name>.peaks`.
  - **Header:** magic `SFPK`, version `1` (UInt32), the source's byte size (UInt64), its modification time (Float64, seconds since 1970), sample rate (Float64) and frames (Int64). The peaks follow.
  - **Reading:** read with `AVAudioFile` in 1 s chunks in its processing format. Use the first channel.

- [ ] **Step 1: Write the failing tests.**

  They write test WAVs with `AVAudioFile` (48 kHz mono float) in a temp folder.

  ```swift
  @Test func toneThenSilence() async throws {
      // 1 s of a 0.5-amplitude sine, then 1 s of zeros
      let p = try await WaveformPeaks.load(audioFile: wav, cacheFolder: cache)
      #expect(p.peaks.count == 200); #expect(abs(p.duration - 2) < 1e-9)
      #expect(p.peaks[0..<100].allSatisfy { abs(Int($0) - 128) <= 2 })
      #expect(p.peaks[100..<200].allSatisfy { $0 == 0 })
  }
  @Test func secondLoadUsesTheCache()        // delete nothing; overwrite the cache's peak bytes with 7s → second load returns 7s
  @Test func aChangedFileIsRecomputed()      // rewrite the WAV (different length) → peaks.count follows the new file
  @Test func unreadableFileThrows()          // 100 bytes of junk named .flac → load throws
  @Test func cancellationStopsPromptly() async throws {
      // a 30 min silent WAV; start load in a Task, cancel after 50 ms; the task throws CancellationError within 1 s
  }
  ```
- [ ] **Step 2: Run them and see them fail**

  Run: `swift test --filter WaveformPeaksTests`

  Expected: FAIL. `WaveformPeaks` is not defined.
- [ ] **Step 3: Implement `WaveformPeaks.load(audioFile:cacheFolder:)` in `Sources/Recording/WaveformPeaks.swift`.**
  - If a cache read fails or the cache doesn't match the file, recompute.
  - If the cache write fails, return the peaks anyway; the cache is only a speed-up.
- [ ] **Step 4: Run them and see them pass**

  Run: `swift test --filter WaveformPeaksTests`

  Expected: PASS.
- [ ] **Step 5: Commit**

  `git commit -m "feat(recordings): waveform peaks per 10 ms, cached beside the log"`

### Task 3: `RecordingsLibrary`, kept current by `AppModel`

**Files:**
- Create: `Sources/SubFloor/App/RecordingsLibrary.swift`
- Modify: `Sources/SubFloor/App/AppModel.swift`. Changes:
  - own `library`;
  - call `library.didLog` after a successful `appendToLog`;
  - call `library.setLive` from the recording-status poll;
  - call `library.setFolder` when `recording.folder` changes;
  - start `reload()` at init.
- Test: `Tests/SubFloorTests/RecordingsLibraryTests.swift`

**Interfaces:**
- Consumes: Task 1's types and `RecordingLog.allEntries()`; `RecordingLog.append`.
- Produces:
  ```swift
  @MainActor @Observable final class RecordingsLibrary {
      init(folder: URL)
      private(set) var folder: URL
      private(set) var catalog: RecordingsCatalog
      var unheardCount: Int { get }
      var onError: ((String) -> Void)?                 // AppModel shows it as an error banner
      func url(for file: String) -> URL
      func setFolder(_ folder: URL)                    // replaces the catalog and starts a reload
      func reload() async                              // folder listing + allEntries(), read off the main actor
      func refreshFiles() async                        // folder listing only (Finder deletions)
      func didLog(_ entries: [RecordingLogEntry])      // AppModel's own writes, applied without rereading
      func setLive(_ live: LiveRecording?)
      func markHeard(_ file: String)                   // no-op if already heard or in progress; else appends .heard(file, now)
      func clear()                                     // one append of .heard for every unheard file
      func measureMissingLengths(onUTCDay day: Date) async   // AVAudioFile length for recordings with seconds == nil
  }
  // AppModel
  let library: RecordingsLibrary
  ```
  - A `reload` that finishes after a `setFolder` to another folder is discarded. Compare the folder it started with.
  - **The live recording:** while `recordingStatus[.audio]` is recording and has a `url`, the library gets `LiveRecording` with:
    - the file name and `startedAt`;
    - `duration`;
    - the frequency and mode of `recordingTuning`, as logged;
    - `isAuto`.

    Otherwise it gets nil.

- [ ] **Step 1: Write the failing tests.** They use a temp folder, files created as empty placeholders where only names matter, and log lines written through `RecordingLog`.
  ```swift
  @Test func reloadReadsTheFolderAndEveryLog() async   // 2 files, entries on two days → catalog has both, unheardCount == 2
  @Test func markHeardWritesOneLineAndDropsTheCount() async   // count 2 → 1; the day's log gained exactly one heard line; a second markHeard writes nothing
  @Test func clearMarksEverythingHeard() async          // 3 unheard → 0; next reload() from disk still 0
  @Test func didLogUpdatesWithoutReading() async        // didLog([.recording(...)]) for a listed file → unheardCount +1 with no reload
  @Test func setFolderReloadsFromTheNewFolder() async   // folder A (2 unheard) → setFolder(B) (1 unheard) → after reload, count == 1 and no A files remain
  @Test func refreshFilesDropsDeletedFiles() async      // remove a file from disk, refreshFiles() → recording gone, count drops
  @Test func logWriteFailureReportsOnce() async         // make .subfloor read-only; markHeard twice → onError called once
  ```
- [ ] **Step 2: Run them and see them fail**

  Run: `swift test --filter RecordingsLibraryTests`

  Expected: FAIL. `RecordingsLibrary` is not defined.
- [ ] **Step 3: Implement `RecordingsLibrary` and wire it into `AppModel` as described above.**

  The folder listing is `contentsOfDirectory` names (no file attributes). The library sees only lines `AppModel` actually wrote: it calls `didLog` after `append` succeeds.
- [ ] **Step 4: Run them, plus the existing app tests, and see them pass**

  Run: `swift test --filter "RecordingsLibraryTests|AutoRecordControlTests"`

  Expected: PASS.
- [ ] **Step 5: Commit**

  `git commit -m "feat(recordings): library of recordings kept current from the folder, the log and the live recording"`

### Task 4: `RecordingPlayer`, and muting the live radio while it plays

**Files:**
- Create: `Sources/SubFloor/App/RecordingPlayer.swift`
- Modify: `Sources/SubFloor/App/AppModel.swift`. Changes:
  - add `liveAudioMuted`;
  - make `volume` and `liveAudioMuted` push `liveAudioMuted ? 0 : volume` to the engine, while the session keeps saving `volume`;
  - own `player`, and set `player.volume` when `volume` changes;
  - call `player.reconcile` after the library changes.
- Test: `Tests/SubFloorTests/RecordingPlayerTests.swift`

**Interfaces:**
- Consumes: `RecordingsLibrary.markHeard`, `url(for:)`, `catalog`; `CatalogRecording`.
- Produces:
  ```swift
  @MainActor @Observable final class RecordingPlayer {
      static let jumpSizes: [Double] = [0.1, 0.5, 1, 5, 30, 300]
      var jump: Double = 1                       // one of jumpSizes; Part 3's Dial sets it too
      var volume: Float                          // 0…1, the main volume knob
      private(set) var file: String?
      private(set) var start: Date?              // the loaded recording's first sample
      private(set) var duration: Double          // 0 when nothing is loaded
      private(set) var position: Double          // seconds into the file
      private(set) var isPlaying: Bool
      private(set) var loadError: String?        // "Can't play this file" when load failed
      var playheadTime: Date? { get }            // start + position
      init(library: RecordingsLibrary, setLiveMuted: @escaping (Bool) -> Void)
      func load(_ recording: CatalogRecording)   // stops what was loaded; refuses inProgress; position 0
      func unload()
      func play()                                // marks heard, mutes live, starts at position
      func pause()                               // unmutes live
      func togglePlay()
      func seek(to seconds: Double)              // clamped to 0...duration; keeps playing if playing
      func move(jumps n: Int)                    // seek(to: position + Double(n) * jump)
      func reconcile(with catalog: RecordingsCatalog)   // unload if the loaded file is gone
  }
  ```
  - **Playback:** use `AVAudioPlayer`. While playing, a 30 Hz timer on the main run loop in `.common` mode updates `position`.
  - **At the end of the file:** the delegate sets `isPlaying` false, `position = duration`, and unmutes.

- [ ] **Step 1: Write the failing tests.** They use a 3 s 48 kHz WAV in a temp recordings folder, with a logged `recording` entry so the file is unheard.
  ```swift
  @Test func playMarksHeardAndMutesLive() async   // play() → isPlaying, setLiveMuted(true) seen, library.unheardCount == 0
  @Test func pauseUnmutes() async                 // play(), pause() → last setLiveMuted value false
  @Test func seekClampsAndMoveUsesTheJump() async // seek(to: -1) → 0; seek(to: 99) → 3; jump = 0.5, seek(1), move(jumps: 2) → 2.0; move(jumps: -9) → 0
  @Test func playingToTheEndStopsAndUnmutes() async   // seek(2.9), play(), wait until !isPlaying (≤ 2 s) → position == 3, live unmuted
  @Test func unreadableFileShowsAnError() async   // junk .flac → loadError == "Can't play this file", play() does nothing
  @Test func inProgressRecordingsCannotLoad() async   // load(recording with inProgress) → file == nil
  @Test func deletedFileUnloads() async           // play(), delete the file, library.refreshFiles(), reconcile → file == nil, not playing, live unmuted
  @Test func liveVolumeIsZeroWhileMuted()         // AppModel: volume 0.4, liveAudioMuted = true → engine volume pushed 0; false → 0.4; saved session volume stays 0.4
  ```
  The last test needs to see the volume pushed to the engine. If `AppModel` has no hook for it, add an internal `effectiveVolume` and assert on that.
- [ ] **Step 2: Run them and see them fail**

  Run: `swift test --filter RecordingPlayerTests`

  Expected: FAIL. `RecordingPlayer` is not defined.
- [ ] **Step 3: Implement `RecordingPlayer` and the `AppModel` changes.**
- [ ] **Step 4: Run them and see them pass**

  Run: `swift test --filter "RecordingPlayerTests|RecordingsLibraryTests"`

  Expected: PASS.
- [ ] **Step 5: Commit**

  `git commit -m "feat(recordings): player that marks recordings heard and mutes the live radio while it plays"`

### Task 5: The Recordings window, header and Lanes timeline

**Files:**
- Create:
  - `Sources/SubFloor/UI/Recordings/RecordingsWindow.swift`
  - `Sources/SubFloor/UI/Recordings/TimelineView.swift`
  - `Sources/SubFloor/UI/Recordings/TimelineGeometry.swift`
  - `Sources/SubFloor/UI/Recordings/RecordingsFormat.swift`
- Modify: `Sources/SubFloor/App/SubFloorApp.swift`. Add a `Window("Recordings", id: "recordings")` scene with the model in its environment and a default size of 1100×640. Add the `Recordings…` ⌘⇧L item to the Radio menu, above "Show Recordings in Finder".
- Test: `Tests/SubFloorTests/RecordingsUITests.swift`

**Interfaces:**
- Consumes: `AppModel.library`, `AppModel.player`; Task 1's `recordings(onUTCDay:)`, `lanes(onUTCDay:)`, `pops(onUTCDay:)`.
- Produces:
  ```swift
  struct TimelineGeometry {
      static let minMarkerWidth: CGFloat = 6, laneHeight: CGFloat = 34, popRowHeight: CGFloat = 22
      let dayStart: Date        // UTC midnight
      let width: CGFloat        // the plotting width, after the lane label column
      func x(for date: Date) -> CGFloat                 // 0…width over 24 h, clamped
      func markerRect(start: Date, seconds: Double, lane: Int) -> CGRect   // min width, clipped at width
      func recording(at point: CGPoint, in markers: [(file: String, rect: CGRect)]) -> String?   // the topmost hit; a 3 pt slop
  }
  enum RecordingsFormat {
      static func clock(_ date: Date) -> String          // "07:48:12.4Z", tenths truncated
      static func length(_ seconds: Double) -> String    // "48 s", "3 min 47 s", "1 h 12 min"
      static func dayTitle(_ dayStart: Date) -> String   // "Tue 27 Oct 2026 UTC"
  }
  ```

**Window behaviour:**
- **Header:** the day, ‹ › to step days, `Today`, the unheard count ("3 unheard"), `Clear` (calls `library.clear()`) and `Show in Finder`. With a recording selected, Show in Finder reveals that file; otherwise it reveals the folder.
- **Timeline:** one `Canvas`. Lane labels sit in a 130 pt column on the left, with hour ticks across.
- **Markers** are rounded pills in the lane colour, with a soft glow (a blurred copy underneath):
  - **Unheard:** full brightness plus a small dot above the pill's leading edge.
  - **Heard:** 60% opacity.
  - **Manual:** outline only.
  - **Selected:** a stronger glow and a 1.5 pt white outline.
  - **In progress:** striped. It grows with the live length and can't be selected.
- **Pops row:** a dot per ignored pop at 25% white, with "N pops" at the left.
- **Now line:** a 1 pt `#ff5a5f` line, on today only.
- **Hover:** a small overlay label near the pointer, through `onContinuousHover`. It shows `18:32:19Z · 7.8 s · 11.175 MHz USB`.
- **Clicking a marker** selects it and loads it into the player. Clicking empty space deselects.
- **While the window is open:**
  - `.task` runs `library.refreshFiles()` every 5 s;
  - `measureMissingLengths` runs for the shown day;
  - on today's view, a 1 s tick moves the now line.
- **Opening the window** shows today, or the day of the newest unheard recording if today has none. Closing it pauses the player.

- [ ] **Step 1: Write the failing tests**
  ```swift
  @Test func geometryPlacesTimesAcrossTheDay()   // width 1200: 00:00 → 0, 12:00 → 600, 24:00 → 1200, the next day → 1200
  @Test func shortClipsKeepAClickableWidth()     // 20 s clip → width == 6
  @Test func clipsCrossingMidnightAreClipped()   // 23:00 start, 7200 s → maxX == 1200
  @Test func hitTestFindsTheMarker()             // point inside, and 2 pt outside (slop) → file; 10 pt away → nil
  @Test func clockFormat()                       // 07:48:12.46Z → "07:48:12.4Z"; 23:59:59.99Z → "23:59:59.9Z"
  @Test func lengthFormat()                      // 7.8 → "7.8 s", 48 → "48 s", 227 → "3 min 47 s", 4320 → "1 h 12 min"
  ```
- [ ] **Step 2: Run them and see them fail**

  Run: `swift test --filter RecordingsUITests`

  Expected: FAIL. `TimelineGeometry` is not defined.
- [ ] **Step 3: Implement the geometry, the formats, the window, the timeline and the scene, as described above.** Use the Global Constraints colours.
- [ ] **Step 4: Run them and see them pass, then build the app**

  Run: `swift test --filter RecordingsUITests && swift build`

  Expected: PASS and a clean build.
- [ ] **Step 5: Commit**

  `git commit -m "feat(recordings): Recordings window with the day timeline in lanes"`

### Task 6: The player panel, waveform and scrubbing

**Files:**
- Create:
  - `Sources/SubFloor/UI/Recordings/PlayerPanel.swift`
  - `Sources/SubFloor/UI/Recordings/WaveformView.swift`
  - `Sources/SubFloor/UI/Recordings/WaveformZoom.swift`
- Modify: `Sources/SubFloor/UI/Recordings/RecordingsWindow.swift` (the panel goes under the timeline)
- Test: `Tests/SubFloorTests/RecordingsUITests.swift`

**Interfaces:**
- Consumes: `RecordingPlayer` (Task 4), `WaveformPeaks.load` (Task 2) with `cacheFolder` `<folder>/.subfloor/peaks`, and `RecordingsFormat` (Task 5).
- Produces:
  ```swift
  struct WaveformZoom: Equatable {
      static let maxScale: Double = 600     // a 1.5 h file zooms down to ~9 s across
      var scale: Double = 1                 // 1 = whole file
      /// The visible span in seconds, centred on `playhead` but kept inside 0...duration.
      func visibleRange(duration: Double, playhead: Double) -> ClosedRange<Double>
      func seconds(atX x: CGFloat, width: CGFloat, duration: Double, playhead: Double) -> Double
      mutating func zoom(by factor: Double)  // clamped to 1...maxScale
  }
  ```

**Panel layout:**
- **Title line:** the lane title, start clock, length and Auto/Manual. On the right, a large monospaced clock showing `RecordingsFormat.clock(player.playheadTime)`, using `Theme.readout`.
- **Waveform:** a `Canvas` of the peaks in the visible range, mirrored about the centre line.
  - Scale to the file's own largest peak, so −17 dBFS speech fills the height.
  - Draw squelched stretches as a flat line.
  - Draw the playhead as a 1.5 pt white line.
  - While peaks load, show a thin progress shimmer. Cancel the load task when the selection changes.
- **Mouse:** clicking or dragging calls `player.seek`. Pinch (`MagnifyGesture`) or ⌘-scroll changes `WaveformZoom.scale`.
- **Controls:** a play/pause button, then jump chips `0.1 s 0.5 s 1 s 5 s 30 s 5 min`. Tapping a chip sets `player.jump`; the selected chip is filled.
- **Keys** (`onKeyPress` on the window content):
  - Space → `togglePlay()`;
  - ← / → → `move(jumps: ∓1 / ±1)`;
  - ⇧← / ⇧→ → step to the previous or next recording on the day.
- **Nothing selected:** "Pick a recording on the timeline". If `loadError` is set, show it.

- [ ] **Step 1: Write the failing tests**
  ```swift
  @Test func wholeFileAtScaleOne()          // duration 100, any playhead → 0...100
  @Test func zoomCentresOnThePlayhead()     // scale 10, duration 100, playhead 50 → 45...55
  @Test func zoomStaysInsideTheFile()       // scale 10, playhead 1 → 0...10; playhead 99 → 90...100
  @Test func xMapsToSeconds()               // scale 10, playhead 50, width 1000: x 0 → 45, x 500 → 50, x 1000 → 55
  @Test func zoomIsClamped()                // zoom(by: 0.1) from 1 → 1; zoom(by: 1e6) → 600
  ```
- [ ] **Step 2: Run them and see them fail**

  Run: `swift test --filter RecordingsUITests`

  Expected: FAIL. `WaveformZoom` is not defined.
- [ ] **Step 3: Implement `WaveformZoom`, the waveform and the panel, as described above.**
- [ ] **Step 4: Run them and see them pass, then build**

  Run: `swift test --filter RecordingsUITests && swift build`

  Expected: PASS and a clean build.
- [ ] **Step 5: Commit**

  `git commit -m "feat(recordings): player panel with a zoomable waveform, mouse and key scrubbing, and jump chips"`

### Task 7: The Recordings button and its badge

**Files:**
- Modify: `Sources/SubFloor/UI/TopBarView.swift`. Add a `RecordingsButton` after `AutoRecordButton()` in `RecordCluster`; it calls `openWindow(id: "recordings")`.
- Create: `Sources/SubFloor/UI/Recordings/RecordingsBadge.swift`
- Test: `Tests/SubFloorTests/RecordingsUITests.swift`

**Interfaces:**
- Produces: `enum RecordingsBadge { static func text(_ count: Int) -> String? }` returns nil for 0 or less, `"7"`, `"99"`, and `"99+"` for 100 and up.

**The button:**
- A plain button styled like the record buttons, with the `waveform` SF Symbol and the title "Recordings". It stays enabled with the radio stopped.
- The badge is a red capsule (`Color.red`, white 10 pt bold text) overlaid at the top trailing corner, offset to sit half outside the button.
- Help text is "Recordings (⌘⇧L) — N unheard"; the accessibility value is "N unheard".

- [ ] **Step 1: Write the failing test** `@Test func badgeText()` with the cases above.
- [ ] **Step 2: Run it and see it fail**

  Run: `swift test --filter RecordingsUITests`

  Expected: FAIL.
- [ ] **Step 3: Implement the badge text and the button.**
- [ ] **Step 4: Run the whole suite and build the app**

  Run: `swift test 2>&1 | grep -E "✘|Test run"` and `./scripts/bundle.sh`

  Expected: no new failures. The known wall-clock flake `SignalClassifierTests.classifierCost` may fail under full-suite load; re-run it alone.
- [ ] **Step 5: Commit**

  `git commit -m "feat(recordings): Recordings button with a red unheard badge"`

### Task 8: Check it in the running app

No code. It needs the user's screen unlocked, because screenshots of a locked screen come back black. Today's real log and recordings are in `~/Music/SubFloor/`. Back up the defaults first, as before.

- [ ] **Step 1:** Launch `build/SubFloor.app`. The Recordings button shows the badge with today's unheard count.
- [ ] **Step 2:** Open Recordings with ⌘⇧L. Check:
  - the 27 Oct lane `11.175 MHz USB` shows 12 markers;
  - the pops row reads "134 pops";
  - hovering a marker shows its time, length and frequency.
- [ ] **Step 3:** Select the 19:46:39Z recording and play it:
  - the live radio goes quiet;
  - the clock runs;
  - clicking the waveform jumps;
  - Space pauses and live audio returns;
  - ← → move by the chosen chip;
  - ⌘-scroll zooms;
  - the badge drops by one.
- [ ] **Step 4:** Press `Clear`; the badge disappears. Delete a test copy of a recording in Finder and see its marker vanish within 5 s. Restore the defaults.

## Self-review notes

- **Spec coverage:**

  | Spec section | Task |
  |---|---|
  | §4.1 button, badge, menu | Tasks 5, 7 |
  | §4.2 header, lanes, markers, pops, now line, hover, live growth | Task 5 |
  | §4.3 folder scan, log merge, live refresh | Tasks 1, 3 |
  | §4.4 heard, Clear | Tasks 1, 3, 4 |
  | §5 title, clock, waveform, zoom, mouse, keys, chips, muting, volume | Tasks 4, 6 |
  | §7 timeline model tests | Task 1 |

  §5's "chosen on the Dial" is Part 3; `jump` is ready for it.
- **Builder's calls made here:**
  - Unheard is decided from the log, so files without log entries (pre-Part-1 files, rolled WAV parts) are heard.
  - A recording in progress doesn't count toward the badge until it ends.
  - Peaks are cached per file under `.subfloor/peaks/`.
  - The window refreshes the folder every 5 s while open.
  - ⇧←/⇧→ step between recordings.
  - When today is empty, the window opens on the day of the newest unheard recording.
