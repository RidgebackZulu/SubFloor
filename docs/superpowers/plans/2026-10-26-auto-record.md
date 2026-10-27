# Auto-Record on Squelch Implementation Plan (Part 1 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When Auto is on, the squelch opening for long enough starts an audio recording that begins 0.5 s before the gate first opened, stays open through fades, and ends 2 s after the gate last shut once it has been shut for *Stop after*. Ignored pops are logged for the timeline.

**Architecture:** A pure `AutoRecordTrigger` state machine in the `Recording` target turns the receiver's gate state, block by block, into frame-exact start / commit / stop / pop events. An `AutoRecorder` wraps the existing audio `StreamRecorder`. On the DSP thread it pushes the audio, runs the trigger and applies its events. `StreamRecorder` gains auto sessions that begin at a past frame and only write up to a committed frame, so FLAC/ALAC files never need truncating. The app wires settings, state, persistence, the Auto button, sleep prevention, disk checks, and a per-day JSON-lines log.

**Tech Stack:** Swift 6, Synchronization (`Mutex`, `Atomic`), SwiftUI, Swift Testing. Same targets as today; one new executable target, `AutoRecordReplay`.

**Spec:** `docs/superpowers/specs/2026-10-26-auto-record-design.md` (§1–3, §4.3 log writing, §7). Part 2 (the Recordings window) and Part 3 (Dial scrub mode) get their own plans after this one ships.

## Global Constraints

- Swift 6 strict concurrency, macOS 15, Apple Silicon. Match the surrounding code's style: `///` doc comments explaining *why*, `Mutex`/`Atomic` from Synchronization, Swift Testing (`@Suite`, `@Test`, `#expect`).
- No file I/O, no allocation in steady state, and no blocking on the DSP thread. Event arrays are reused (`removeAll(keepingCapacity:)`). Locks guard memcpy-sized sections only, as `HistoryRing` does.
- Audio only. IQ recording is untouched; IQ files never trigger and are never logged.
- Trigger timing: *Start after* default 2 s (range 0.5–10 s, step 0.5); *Stop after* default 30 s (choices 5, 10, 15, 30, 45, 60, 90, 120, 180, 300, 600 s); bridge 1.5 s; lead 0.5 s; tail 2 s.
- Any reopening of the gate, however short, restarts the *Stop after* countdown (user decision). A fast run of crashes may start a file (accepted).
- Never trigger on the Demo (synthetic) source. IQ file sources do trigger.
- Banner copy, exact: `Auto-record needs the squelch on.` · `Auto-record is off: less than 100 MB free where recordings go.` The existing `Less than 500 MB free where recordings go.` warning is reused.
- File names are unchanged (`RecordingNames`). Auto vs manual lives only in the log.
- Log: `<recordings folder>/.subfloor/<yyyy-MM-dd>.jsonl`, UTC date of the entry's time, one JSON object per line, append-only.
- Tests that run the engine assert on captured amounts, not wall-clock time: the debug demo source runs slower than real time.

## Review Focus

1. **Changing *Start after* / *Stop after* while recording** must not end the recording or drop the pre-roll. The audio ring is always sized for the largest holdback, so a timing change never rebuilds it. Test in Task 6.
2. **Turning the squelch off (or Auto off) mid-recording** ends the file at last-open + tail, not at the moment of the click, and the file is valid. Test in Task 4.
3. **Stopping the radio mid-auto-recording** finalises the file and logs it with `auto: true`. Test in Task 6.
4. **Turning Auto on while a signal is already present** starts a recording *Start after* later, beginning 0.5 s before Auto was turned on, never earlier. Test in Task 2.
5. **A recording or pop just before 00:00 UTC** is logged in the file for its own (start) date. Test in Task 5.

---

### Task 1: Capture real IQ for tuning (runs in the background while Tasks 2–7 proceed)

No code. Uses the attached RSP1B. The memory notes say to drive the app via defaults keys, and that a stale SDRplay service lock needs a service restart.

- [ ] **Step 1:** Run SubFloor on the RSP1B at the lowest output rate the RSP offers that is ≥ 250 kS/s. Tune 11.175 MHz USB, 2.7 kHz. Record IQ (16-bit WAV) for at least 3 hours of daytime into `~/Music/SubFloor/captures/`, which is outside the repository. Expect about 1 MB/s.
- [ ] **Step 2:** In the evening (00–04 UTC), record 6.925 MHz the same way for at least 2 hours, ideally while a pirate is on.
- [ ] **Step 3:** Note in `~/Music/SubFloor/captures/NOTES.txt` the times of real transmissions you heard, if any, and the squelch level that sat just above the noise. Task 8 uses these. Nothing is committed.

### Task 2: `AutoRecordTrigger`, the pure state machine

**Files:**
- Create: `Sources/Recording/AutoRecordTrigger.swift`
- Test: `Tests/RecordingTests/AutoRecordTriggerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct AutoRecordTiming: Equatable, Sendable, Codable {
      public var startAfter = 2.0, stopAfter = 30.0   // seconds
      public static let bridge = 1.5, lead = 0.5, tail = 2.0
      public static let startAfterRange = 0.5...10.0
      public static let stopAfterChoices: [Double] = [5, 10, 15, 30, 45, 60, 90, 120, 180, 300, 600]
      /// The most the audio ring must hold behind the head for any timing.
      public static let maxHoldbackSeconds = 600 + 10 + bridge + lead   // 612
      public func normalized() -> AutoRecordTiming   // clamps startAfter, snaps stopAfter to the nearest choice
  }
  public struct AutoRecordTrigger: Sendable {
      public enum Event: Equatable, Sendable {
          case start(atFrame: Int)            // the file's first frame
          case commit(throughFrame: Int)      // the writer may write frames < this
          case stop(atFrame: Int)             // the file ends before this frame
          case pop(atFrame: Int, frames: Int) // an ignored run: first open frame, open span
      }
      public init(sampleRate: Double, timing: AutoRecordTiming)
      public var timing: AutoRecordTiming      // settable any time; applies from the next block
      public private(set) var isRecording: Bool
      /// `head` is the recorder's frame count after this block; `gateOpen` applies to the frames since the last call.
      public mutating func advance(to head: Int, gateOpen: Bool, into events: inout [Event])
      /// Retune, squelch off, Auto off: ends a recording at min(head, lastOpenEnd + tail); discards an undecided run (no pop).
      public mutating func cut(into events: inout [Event])
  }
  ```

The rules, from spec §3.1, all in frames (`seconds × sampleRate`, rounded):
- The first `advance` call after `init` only records the baseline head, so frames before Auto was on are never counted.
- A head lower than the last one (the ring was rebuilt) resets to idle and emits nothing.
- *Idle*, gate open → a run begins at the previous head.
- *In a run*: open frames add up. When the gate has been shut for more than `bridge` since the last open frame, emit `.pop` and go idle. When the open total reaches `startAfter`, emit `.start(atFrame: max(0, runStart − lead))` and then `.commit(throughFrame: head)`.
- *Recording*: commit `min(head, lastOpenEnd + tail)` whenever it grows. When `head − lastOpenEnd ≥ stopAfter`, emit `.stop(atFrame: lastOpenEnd + tail)` (never above head) and go idle.

- [ ] **Step 1: Write the failing tests.** Rate 1,000 frames/s; a helper `feed(_:[(seconds: Double, open: Bool)], timing:) -> [Event]` advances in 10-frame blocks from a baseline call at head 0.

```swift
@Test func popsShorterThanStartAfterMakeNoRecording() {
    let e = feed([(1, false), (0.3, true), (5, false)])
    #expect(e == [.pop(atFrame: 1_000, frames: 300)])
}
@Test func speechWithSyllableGapsStartsHalfASecondBeforeTheFirstWord() {
    let e = feed([(10, false)] + Array(repeating: [(0.4, true), (0.2, false)], count: 6).flatMap { $0 })
    #expect(e.first == .start(atFrame: 9_500))
    #expect(!e.contains { if case .pop = $0 { true } else { false } })
}
@Test func gapsLongerThanTheBridgeResetTheCount() {
    let e = feed([(0.5, false), (1.5, true), (1.6, false), (1.5, true), (5, false)])
    #expect(e == [.pop(atFrame: 500, frames: 1_500), .pop(atFrame: 3_600, frames: 1_500)])
}
@Test func aBriefReopenWithinStopAfterKeepsOneRecording() {
    let e = feed([(1, false), (5, true), (20, false), (0.1, true), (40, false)])
    #expect(e.filter { if case .start = $0 { true } else { false } } == [.start(atFrame: 500)])
    #expect(e.last == .stop(atFrame: 28_100))   // last open ends at 26_100, + 2 s tail
}
@Test func commitsNeverPassTheStopAndEndOnIt() {
    let e = feed([(1, false), (5, true), (40, false)])
    let commits = e.compactMap { if case .commit(let f) = $0 { f } else { nil } }
    #expect(commits.allSatisfy { $0 <= 8_000 } && commits.last == 8_000 && e.last == .stop(atFrame: 8_000))
}
@Test func cutWhileOpenStopsAtTheHead()            // 1 s shut, 5 s open, cut → last event .stop(atFrame: 6_000)
@Test func cutDuringAnUndecidedRunDiscardsIt()     // 1 s open, cut → no events at all
@Test func aShrinkingHeadResetsSilently()          // recording, then advance(to: 0) → no events, isRecording false
@Test func autoTurnedOnMidSignalStartsAfterStartAfter() {
    var t = AutoRecordTrigger(sampleRate: 1_000, timing: .init()); var e: [AutoRecordTrigger.Event] = []
    t.advance(to: 50_000, gateOpen: true, into: &e)          // baseline: Auto just turned on
    var head = 50_000
    while e.isEmpty { head += 10; t.advance(to: head, gateOpen: true, into: &e) }
    #expect(head == 52_000 && e.first == .start(atFrame: 49_500))
}
@Test func timingNormalizesToTheAllowedValues()    // startAfter 0.1 → 0.5, 20 → 10; stopAfter 40 → 45 (nearest choice), 7 → 5
```

- [ ] **Step 2:** Run `swift test --filter AutoRecordTriggerTests`. Expected: FAIL, `AutoRecordTrigger` not defined.
- [ ] **Step 3:** Implement `AutoRecordTiming` and `AutoRecordTrigger` in `Sources/Recording/AutoRecordTrigger.swift` per the rules above.
- [ ] **Step 4:** Run `swift test --filter AutoRecordTriggerTests`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(recording): AutoRecordTrigger turns squelch gate runs into recordings and ignored pops`.

### Task 3: Auto sessions in `StreamRecorder`

**Files:**
- Modify: `Sources/Recording/StreamRecorder.swift` (Setup, `plan`, `RecordingStatus`, commands, `begin`, `drain`)
- Test: `Tests/RecordingTests/RecordingTests.swift` (`StreamRecorderTests`, `FormatTests`)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  ```swift
  // Setup gains (default 0, so existing callers are unchanged):
  public var holdbackSeconds: Double
  // plan gains the same parameter; capacity covers preRoll + holdback + margin, preRollBytes is unchanged:
  public static func plan(sampleRate: Double, bytesPerFrame: Int, preRollSeconds: Double, holdbackSeconds: Double = 0, memoryLimitBytes: Int) -> RingPlan
  public enum SessionKind: Int, Sendable { case none, auto, manual }
  public var sessionKind: SessionKind { get }      // atomic; cheap on the DSP thread
  public var headFrame: Int { get }                 // frames pushed since the last ring reset
  public func start(fromFrame: Int)                 // auto session; ignored while any session is open
  public func commit(throughFrame: Int)             // atomic, only grows; auto sessions write frames < this
  public func stop(atFrame: Int)                    // ends an auto session there; ignored for manual sessions
  // RecordingStatus gains:
  public var isAuto = false
  ```
- Changed behaviour of the existing `start()`: while an auto session is open, it converts that session to manual (no commit limit, `isAuto = false`, `sessionKind == .manual`). It does not start a new file.

The approach: `Command` gets `.startAuto(byte: Int)` and `.stopAuto(byte: Int)`. `Session` gets `isAuto` and the writer reads the commit atomic. In `drain`, an auto session's `want` is also bounded by `committedByte − position`. A stop byte below `position` is clamped to `position`. A start frame the ring no longer holds clamps to the oldest available frame (as `rewind` already does).

- [ ] **Step 1: Write the failing tests** in `StreamRecorderTests`, using the existing helpers. Rate is 10,000 and frame value = frame index.

```swift
@Test func autoSessionStartsAtTheRequestedFrameAndEndsAtTheStop() throws {
    // push 0..<100_000; start(fromFrame: 95_000); commit(throughFrame: 100_000); wait for url;
    // push 100_000..<110_000; commit(throughFrame: 104_000); stop(atFrame: 104_000); wait not recording
    #expect(frames.first == 95_000 && frames.last == 103_999 && frames.count == 9_000)
    #expect(status.isAuto && status.startedAt == click.addingTimeInterval(-0.5))
}
@Test func autoWriterNeverPassesTheCommit() throws {
    // start(fromFrame: 95_000); commit(throughFrame: 97_000); push 20_000 more; sleep 0.2 s
    #expect(r.status.framesWritten == 2_000)
}
@Test func manualStartTakesOverAnAutoSession() throws {
    // start(fromFrame: 95_000); commit 96_000; start(); stop(atFrame: 96_000) is ignored;
    // push to 110_000; stop(wait: true)
    #expect(r.status.isAuto == false && frames.first == 95_000 && frames.last == 109_999)
}
@Test func autoStartBeyondTheRingClampsToTheOldestFrame() throws   // preRoll 5 s, push 200_000, start(fromFrame: 0) → first frame ≥ 200_000 − capacity frames, contiguous
@Test func sessionKindTracksTheSession()                            // .none → start(fromFrame:) .auto → start() .manual → stop .none
// FormatTests:
@Test func holdbackGrowsTheRingButNotThePreRoll() {
    let p = StreamRecorder.plan(sampleRate: 48_000, bytesPerFrame: 3, preRollSeconds: 30, holdbackSeconds: 612, memoryLimitBytes: 256 << 20)
    #expect(p.preRollBytes == 30 * 48_000 * 3 && p.capacityBytes >= (30 + 612) * 48_000 * 3 && p.effectivePreRollSeconds == 30)
}
```

- [ ] **Step 2:** Run `swift test --filter "StreamRecorderTests|FormatTests"`. Expected: the new tests fail to compile or fail. The existing ones still pass after a compile fix.
- [ ] **Step 3:** Implement the interfaces above in `StreamRecorder.swift`.
- [ ] **Step 4:** Run `swift test --filter RecordingTests`. Expected: all pass, old and new.
- [ ] **Step 5:** Commit: `feat(recording): auto sessions that start at a past frame and write only what is committed`.

### Task 4: `AutoRecorder`, the trigger driving the audio recorder on the DSP thread

**Files:**
- Modify: `Sources/DSPCore/Receiver.swift` (expose the gate)
- Create: `Sources/Recording/AutoRecorder.swift`
- Test: `Tests/DSPCoreTests/ReceiverTests.swift`, `Tests/RecordingTests/AutoRecorderTests.swift`

**Interfaces:**
- Consumes: `AutoRecordTrigger`, `AutoRecordTiming` (Task 2); `StreamRecorder.start(fromFrame:)`, `commit(throughFrame:)`, `stop(atFrame:)`, `headFrame`, `sessionKind`, `now` (Task 3).
- Produces:
  ```swift
  // Receiver:
  public var isSquelchOpen: Bool { get }   // the gate (true when no squelch is set)
  // AutoRecorder:
  public struct IgnoredPop: Equatable, Sendable { public var at: Date; public var seconds: Double }
  public final class AutoRecorder: @unchecked Sendable {
      public struct Config: Equatable, Sendable { public var enabled: Bool; public var timing: AutoRecordTiming }
      public init(recorder: StreamRecorder)
      public let recorder: StreamRecorder
      // any thread
      public func configure(_ config: Config)
      public func cut()                      // retune / mode change
      public func reset()                    // a new run of the radio: the next block is a fresh baseline
      public func drainPops() -> [IgnoredPop]
      public var cuts: Int { get }           // test hook: cut() calls applied
      // DSP thread
      public func process(_ audio: UnsafeBufferPointer<Float>, gateOpen: Bool)
  }
  ```

`process` always pushes the audio to the recorder first. It then applies any pending config, cut or reset. If not enabled, it cuts a recording in progress and returns. If the recorder's session is manual, it discards the trigger's state and returns. Otherwise it advances the trigger to `recorder.headFrame` and applies the events. A pop's `at` is `recorder.now() − (head − frame) / sampleRate`, with the rate taken from `recorder.setup`. Pops queue in a `Mutex<[IgnoredPop]>` capped at 10,000 (drop the oldest).

- [ ] **Step 1: Write the failing tests.**
  - `ReceiverTests`: `@Test func gateStateIsExposed()` — with squelch at noise floor + 10 dB, `isSquelchOpen` is false after 0.5 s of noise and true during the tone burst of `squelchFadesInAndOut`'s signal; with `squelchDb = nil` it is true.
  - `AutoRecorderTests` (rate 48 kHz real `Receiver` in USB at 2.7 kHz, input 250 kS/s, built with `TestSignals.noise` + tone bursts; `StreamRecorder` WAV float32, preRoll 30, holdback 612, `now` fixed). Each test pushes the signal block by block (1,008 IQ samples) through `receiver.process` then `auto.process(audio, gateOpen: receiver.isSquelchOpen)`, waits for the writer, then reads the WAVs.
    ```swift
    @Test func burstsBecomeOneFileAndPopsAreOnlyLogged()
    // 5 s noise; three 0.3 s pops 3 s apart; 4 s noise; 8 s of 0.4 s-on/0.2 s-off bursts; 8 s gap; 1 s burst; 20 s noise;
    // timing startAfter 2, stopAfter 15
    // → exactly 1 file; it starts 0.5 s (±0.05 s) before the first burst and ends 2 s (±0.05 s) after the last burst ends;
    //   drainPops().count == 3; the file's samples before the first burst are all 0 (squelched)
    @Test func turningAutoOffMidRecordingEndsAtLastOpenPlusTail()   // Review Focus 2: configure(enabled: false) 5 s after the last burst → file ends 2 s after it
    @Test func cutEndsTheRecordingAndCounts()                       // cut() while bursts are on → file ends within one block of the cut; cuts == 1
    @Test func manualSessionPausesTheTrigger()                      // recorder.start() before the bursts → one manual file, no auto file, no pops
    ```
- [ ] **Step 2:** Run `swift test --filter "ReceiverTests|AutoRecorderTests"`. Expected: FAIL to compile.
- [ ] **Step 3:** Add `isSquelchOpen` to `Receiver` (it returns the existing private `squelchOpen`). Implement `AutoRecorder` in `Sources/Recording/AutoRecorder.swift`.
- [ ] **Step 4:** Run `swift test --filter "DSPCoreTests|RecordingTests"`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat(recording): AutoRecorder drives the audio recorder from the squelch gate`.

### Task 5: The per-day recording log

**Files:**
- Create: `Sources/Recording/RecordingLog.swift`
- Test: `Tests/RecordingTests/RecordingLogTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum RecordingLogEntry: Codable, Equatable, Sendable {
      case recording(file: String, start: Date, seconds: Double, frequencyHz: Double, mode: String, auto: Bool)
      case pop(at: Date, seconds: Double, frequencyHz: Double, mode: String)
      case heard(file: String, at: Date)   // written by Part 2; defined now so the format is fixed
      public var date: Date                 // start / at
  }
  public struct RecordingLog: Sendable {
      public init(folder: URL)              // the recordings folder; the log lives in folder/.subfloor/
      public func append(_ entries: [RecordingLogEntry]) throws   // groups by UTC day, one JSON line each
      public func entries(forUTCDay day: Date) throws -> [RecordingLogEntry]
      public func fileURL(forUTCDay day: Date) -> URL             // .subfloor/yyyy-MM-dd.jsonl
  }
  ```
`file` is the file name only, not a path, so the folder can move. Dates are encoded as ISO 8601 with fractional seconds. A line that does not decode is skipped by the reader.

- [ ] **Step 1: Write the failing tests.**
  ```swift
  @Test func entriesRoundTripThroughTheDayFile()
  @Test func entriesLandInTheirUTCDay() {   // Review Focus 5
      // a pop at 2026-10-26 23:59:59.5Z and a recording starting 23:59:50Z lasting 30 s → both in 2026-10-26.jsonl;
      // a pop at 2026-10-27 00:00:00.2Z → 2026-10-27.jsonl
  }
  @Test func appendKeepsEarlierLines()
  @Test func aCorruptLineIsSkipped()
  ```
- [ ] **Step 2:** Run `swift test --filter RecordingLogTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `RecordingLog.swift` (FileHandle append, creating `.subfloor/` as needed).
- [ ] **Step 4:** Run `swift test --filter RecordingLogTests`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(recording): per-day JSON-lines log of recordings and ignored pops`.

### Task 6: Engine and app wiring, settings, persistence, unattended running

**Files:**
- Modify: `Sources/Recording/Formats.swift` (`RecordingSettings`)
- Modify: `Sources/SubFloor/Engine/DSPEngine.swift` (own an `AutoRecorder`; `process` in place of `audioRecorder.push`; `reset` in `start`)
- Modify: `Sources/SubFloor/App/AppModel.swift` (state, push, cut, takeover, log, disk, sleep, session)
- Test: `Tests/RecordingTests/RecordingTests.swift` (`FormatTests`), `Tests/SubFloorTests/AutoRecordControlTests.swift` (new)

**Interfaces:**
- Consumes: `AutoRecorder`, `AutoRecordTiming`, `RecordingLog`, `StreamRecorder` additions.
- Produces:
  ```swift
  // RecordingSettings gains, with a hand-written init(from:) that uses decodeIfPresent for every key and
  // falls back to the defaults, so sessions saved before this decode (today a missing key throws and the
  // whole session is lost):
  public var autoTiming = AutoRecordTiming()
  // DSPEngine:
  let autoRecorder: AutoRecorder            // wraps audioRecorder
  // AppModel:
  enum AutoRecordState: Equatable { case off, armed, recording, needsSquelch, needsRadio, demoSource }
  var autoRecordEnabled: Bool               // persisted
  var autoRecordState: AutoRecordState { get }
  var isAutoRecording: Bool { get }         // audio status recording && isAuto
  func toggleAutoRecord()
  var recordingLog: RecordingLog { get }    // for the folder in `recording`
  // SessionState gains optionals: autoRecord: Bool?, squelchEnabled: Bool?, squelchDb: Float?
  ```

The wiring rules (spec §3.3–3.4):
- **What the engine gets.** `pushAutoRecord()` sends `Config(enabled: autoRecordEnabled && isRunning && squelchEnabled && sourceKind != .synthetic, timing: recording.autoTiming)`. It is called from the didSets of `autoRecordEnabled`, `squelchEnabled` and `recording`, and from `start`/`stop`/`useSource`.
- **Ring size.** The audio recorder's Setup uses `holdbackSeconds: AutoRecordTiming.maxHoldbackSeconds` always. A timing change must never change the plan, and so never ends a recording.
- **State order.** `autoRecordState` checks in this order: off → `needsRadio` (not running) → `demoSource` → `needsSquelch` → recording → armed.
- **Turning Auto on.** `toggleAutoRecord()` turning on with squelch off shows the banner `Auto-record needs the squelch on.` (info) and leaves Auto on.
- **Cutting.** When the audio `RecordingContext` (VFO frequency or mode label) changes, call `engine.autoRecorder.cut()`. A capture-centre retune that keeps the VFO does not cut.
- **Manual and auto.**
  - `isRecording(.audio)` now means a *manual* audio recording (`isRecording && !isAuto`), so the Audio/Both buttons ignore auto recordings.
  - `toggleRecording(.audio)` / `startRecording(.audio)` while auto-recording calls `audioRecorder.start()`, which converts the recording to manual.
- **Logging.**
  - In `refreshRecordingStatus`, when the audio status goes from recording to not recording, append `.recording(file:start:seconds:frequencyHz:mode:auto:)` from the previous status. The file name comes from its URL. Frequency and mode come from the context that was current when the recording started: capture these when the status first shows `isRecording`.
  - Each refresh drains `engine.autoRecorder.drainPops()` into `.pop` entries with the current VFO/mode.
  - A log write error shows an error banner once and does not stop recording.
- **Disk.**
  - While Auto is on, check free space where recordings go once a minute (`volumeAvailableCapacityForImportantUsage`).
  - Under 500 MB, show the existing warning banner once per crossing.
  - Under 100 MB, set `autoRecordEnabled = false`, stop an auto recording (`audioRecorder.stop()`), and show the error banner `Auto-record is off: less than 100 MB free where recordings go.`
- **Sleep.** While `autoRecordEnabled && isRunning`, hold `ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Auto-record is listening")`. End it otherwise.
- **Persistence.** `autoRecordEnabled`, `squelchEnabled`, `squelchDb` and `recording.autoTiming` go through `SessionState`. `restoreSession` applies the optionals when present.

- [ ] **Step 1: Write the failing tests.**
  - `FormatTests`: `@Test func settingsSavedBeforeAutoRecordStillDecode()`. Take the JSON of today's `RecordingSettings` (encode a default one, then delete the `autoTiming` key). It decodes, with `autoTiming == AutoRecordTiming()` and the other fields kept.
  - `AutoRecordControlTests` (pattern of `RecordingControlTests`: temp folder, fresh `UserDefaults` suite, `wait` helper, tolerate no audio device):
    ```swift
    @Test func autoNeedsTheSquelch()                 // toggleAutoRecord() with squelch off → enabled, state .needsSquelch, banner "Auto-record needs the squelch on."
    @Test func autoIsOffWhileTheRadioIsStopped()     // enabled, not running → .needsRadio
    @Test func demoSourceNeverTriggers()             // useSource(.synthetic), squelch on, Auto on → .demoSource and the engine's AutoRecorder config has enabled == false
    @Test func autoSettingsAndSquelchPersist()       // autoRecordEnabled, squelchEnabled, squelchDb -97, autoTiming(3, 60) survive shutdown + new AppModel
    @Test func audioButtonTakesOverAnAutoRecording() // demo source running; engine.audioRecorder.start(fromFrame: headFrame) directly;
                                                     // toggleRecording(.audio) → status.isAuto == false, still recording
    @Test func changingStopAfterDoesNotEndARecording()   // Review Focus 1: auto session started directly; recording.autoTiming.stopAfter = 120 → still recording, same url
    @Test func stoppingTheRadioLogsTheAutoRecording()    // Review Focus 3: auto session started directly, commit to head, stop() → today's log has one .recording with auto == true and the file exists
    @Test func vfoChangeCutsAndCentreRetuneDoesNot()     // engine.autoRecorder.cuts goes up by 1 on a VFO step and mode change, not on a centre-only move
    ```
- [ ] **Step 2:** Run `swift test --filter "FormatTests|AutoRecordControlTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement the `RecordingSettings` decoding and the `DSPEngine` change: `autoRecorder.process(audio, gateOpen: receiver.isSquelchOpen)` replaces `audioRecorder.push`, and `autoRecorder.reset()` goes next to the `clearHistory()` calls in `start`.
- [ ] **Step 4:** Implement the `AppModel` rules above.
- [ ] **Step 5:** Run `swift test`. Expected: the whole suite passes. Pre-existing tests that read `isRecording(.audio)` still pass, since they record manually.
- [ ] **Step 6:** Commit: `feat(auto-record): wire squelch auto-record through the engine and app, with persistence, log, disk and sleep guards`.

### Task 7: The Auto button, menu item and settings

**Files:**
- Modify: `Sources/SubFloor/UI/TopBarView.swift` (`RecordCluster`: an `AutoRecordButton` after Both)
- Modify: `Sources/SubFloor/App/SubFloorApp.swift` (`RadioCommands`)
- Modify: `Sources/SubFloor/UI/SettingsView.swift` (`RecordingSection`)

**Interfaces:**
- Consumes: `AppModel.autoRecordState`, `autoRecordEnabled`, `toggleAutoRecord()`, `recordingStatus[.audio]`, `recording.autoTiming`.

**The button.**
- `AutoRecordButton` reuses `RecordButtonLabel` styling. Its states:
  - **off:** plain "Auto".
  - **armed:** "Auto" with a faint red ring, made with a stroke overlay (red, opacity 0.5, 1.5 pt).
  - **recording:** solid red with the elapsed time, like Audio.
  - **needsSquelch / needsRadio / demoSource:** "Auto" with the ring dashed and dimmed, and help text saying why it is waiting. The texts: "Waiting: turn the squelch on" · "Waiting: start the radio" · "Waiting: auto-record never records the demo source".
- It stays enabled when the radio is stopped. Move `.disabled(!model.isRunning)` from the cluster onto the Audio/IQ/Both buttons only.
- Help text when on: "Auto-record: starts after \(startAfter) s of signal, stops after \(stopAfter) s of quiet (⌘⇧T)".

**The menu.** Under the Radio menu's record items: `Button(model.autoRecordEnabled ? "Turn Auto-Record Off" : "Turn Auto-Record On") { model.toggleAutoRecord() }.keyboardShortcut("t", modifiers: [.command, .shift])`.

**Settings.** After the pre-roll row:
- A "Auto-record starts after" slider over `AutoRecordTiming.startAfterRange`, step 0.5, showing "\(x) s".
- A "and stops after" `Picker` over `AutoRecordTiming.stopAfterChoices`, showing "5 s … 10 min".
- The caption: "Auto-record starts when the squelch has been open that long (gaps under 1.5 s don't count against it), begins half a second before the signal, and ends 2 s after the signal once the squelch has stayed shut for the stop time."

- [ ] **Step 1:** Implement the three changes.
- [ ] **Step 2:** Run `swift build` and `swift test --filter SubFloorTests`. Expected: build succeeds; tests pass.
- [ ] **Step 3:** Run the app (the `run` skill, or `scripts/bundle.sh` and open it) on the Demo source. Check four things:
  - The Auto button shows the demo-source waiting state.
  - ⌘⇧T toggles it.
  - With the radio stopped it is still clickable.
  - Settings shows both controls and the values persist across a relaunch.

  Screenshot the top bar in each state.
- [ ] **Step 4:** Commit: `feat(auto-record): Auto button, menu item and settings`.

### Task 8: Replay tool, tuning against the captures, and the live check

**Files:**
- Create: `Sources/AutoRecordReplay/main.swift`
- Modify: `Package.swift` (`.executableTarget(name: "AutoRecordReplay", dependencies: ["DSPCore", "Recording"])`)

**Interfaces:**
- Consumes: `IQFileSource.parseWAVHeader(_:)`, `Receiver`, `AutoRecordTrigger`, `AutoRecordTiming`, `RecordingNames`. The file name gives the centre (`_<Hz>Hz_IQ`).
- Produces the CLI: `swift run -c release AutoRecordReplay <iq.wav> --vfo <Hz> --mode usb|lsb|am --bw <Hz> (--squelch <dBFS> | --above-floor <dB>) [--start <s>] [--stop <s>]`

The tool reads the WAV in blocks of 1,008 frames, faster than real time, through `Receiver` and `AutoRecordTrigger` (no files are written). It prints:
- one line per recording: `REC 14:02:31.5Z  1m52.0s`;
- one line per pop: `pop 14:05:10.2Z  0.4s`;
- a summary: recordings, pops, total recorded time.

Times come from the file name's start time plus the frame offset. `--above-floor N` sets the threshold to the median `signalDb` of the first 60 s, plus N dB.

- [ ] **Step 1:** Implement the tool. Run it on a 2-minute synthetic WAV made with `WAVFile` in a scratch script. The output lists the expected recordings and pops.
- [ ] **Step 2:** Run it on the Task 1 captures with the defaults and `--above-floor` at 6, 8 and 10 dB. Compare against `NOTES.txt` and listen to a few in SubFloor (Open IQ Recording…, Auto on).
  - Pass if every noted transmission is one recording and no pirate show splits.
  - Fail if pops dominate or a show splits: report the numbers to the owner before changing any default. The defaults were agreed with the owner.
- [ ] **Step 3:** Live check. Run on the RSP1B on 11.175 MHz USB with Auto on for at least 3 hours. Afterwards, list the folder and today's `.subfloor` log. Every file must play and start just before the voice, and the log's pops and recordings must line up with the files.
- [ ] **Step 4:** Commit: `feat(auto-record): AutoRecordReplay tool for tuning against IQ captures`. Put the tuning results in the commit message body.
