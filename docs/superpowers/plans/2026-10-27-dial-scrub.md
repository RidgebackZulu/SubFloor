# Dial Scrub Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While the Recordings window is the key window and a playable recording is selected, the SubFloor Dial scrubs that recording: turning moves the playhead by a jump size chosen on the Dial, and the Dial shows the jump, the playhead's UTC time, play/pause and a progress ring.

**Architecture:**
- **App side.** SubFloor works out a *scrub target* from the window's focus, the player and the catalog: nil means the Dial tunes. `DialScrubSync` is a pure struct that turns successive targets into protocol lines. `DialController` sends those lines (only to firmware ≥ 1.1.0) and applies the Dial's `J`/`JUMP`/`PLAY` to `RecordingPlayer`.
- **Firmware side.** On `SCRUB on` the tune screen becomes a scrub screen. The firmware predicts the playhead locally, as it already does the frequency, and reuses the existing gestures.

**Tech Stack:** Swift 6 / SwiftUI (macOS 15), Swift Testing; ESP32-S3 Arduino firmware (PlatformIO, M5Unified), `firmware/tools/dialctl.py`.

**Spec:** `docs/superpowers/specs/2026-10-26-auto-record-design.md`: §6 (Dial scrub mode), §5 (jump sizes, player), §7 (Dial testing).

**Repositories:**
- **SubFloor:** branch `claude/dial-scrub`, stacked on `claude/recordings-window` (PR #4).
- **Firmware:** `/Users/war/Desktop/code/radiodial` (no remote). Branch `scrub` off `main` before Task 4.

## Global Constraints

- **Jump sizes:** exactly `0.1, 0.5, 1, 5, 30, 300` s (`RecordingPlayer.jumpSizes`). The default is SubFloor's current `player.jump`.
- **Scrub mode condition:** the Recordings window is key AND the selected recording is playable. Playable means loaded in the player, with no load error, a length > 0, not in progress, and not marked unplayable by the window (unreadable peaks).
  - Any other state is tune mode, including the window closing or losing key status.
- **Gestures** (scrub screen only; menus are unchanged):

  | Gesture | Effect |
  |---|---|
  | Turn | Move by the jump (no acceleration) |
  | Press | Next coarser jump, wrapping (0.1 → 0.5 → 1 → 5 → 30 → 300 → 0.1) |
  | Hold + turn | Pick the jump (clamped) |
  | Swipe left | Coarser jump (clamped) |
  | Swipe right | Finer jump (clamped) |
  | Tap anywhere | Play/pause |
  | Long-press | Settings, as today |
- **Protocol lines, SubFloor → Dial:**
  - `SCRUB on t0=<s> len=<s> pos=<s> play=<0|1> jump=<j> title=<text>`
    - `title` is always last; the Dial takes everything after `title=`.
    - `t0` is the recording's start as UTC seconds since midnight.
  - `SCRUB off`
  - `POS <s> [seq]`
  - `PLAY <0|1>`
  - `JUMP <j>`
- **Protocol lines, Dial → SubFloor:**
  - `J <seq> <n> <j>`: `n` jumps of `j` seconds.
  - `JUMP <j>`
  - `PLAY`: toggle.
- **Number formats:**
  - `<s>` is `%.2f`. `<j>` is the shortest form: `0.1`, `0.5`, `1`, `5`, `30`, `300`.
  - The Dial accepts any decimal and snaps it to the nearest jump size.
- **Firmware version:**
  - `DIAL_FW_VERSION` becomes `"1.1.0"`.
  - SubFloor sends scrub lines only when the `HELLO` firmware version is ≥ 1.1.0 (compared numerically, component by component). Anything unparsable counts as older.
  - `DialProtocol.version` becomes `2`.
- **Stale-line rules (as for `F`):**
  - The Dial ignores `POS` without `seq` for 400 ms after the knob last moved, or while jumps are unsent.
  - It ignores `POS <s> <seq>` older than its last `J`.
- **Dial clock:** `HH:MM:SS.dZ` (`07:48:12.4Z`), computed from `(t0 + pos) mod 86400`. While playing, `pos` advances locally from the last accepted `POS`, capped at `len`.
- **Dial ring colour:** `0xFF7AC8` (pink, from the lane palette). It must differ from amber `0xFFB847` (tune) and cyan `0x5CD6FF` (bandwidth).
- **Dial text:** the jump chip label is `JUMP`, with values like `0.1 s`, `1 s`, `30 s` and `5 min`. The title is the lane title, e.g. `11.175 MHz USB`.
- **SubFloor sends:**
  - `POS` when the player's position differs from what the Dial would extrapolate by > 0.3 s;
  - `POS` every 5 s while playing;
  - `PLAY` on every play-state change.
- **Firmware link rules:** on `HELLO`, `BYE` or host timeout, the Dial leaves scrub mode. SubFloor resends `SCRUB on` after every `HELLO` while a target exists.
- **No regressions:**
  - Tune, bandwidth, mode, menus and Bluetooth behave exactly as in 1.0.0 whenever scrub mode is off.
  - SubFloor talking to 1.0.0 firmware behaves exactly as today.

## Review Focus

1. **A Dial on 1.0.0 firmware** while the Recordings window is key: SubFloor sends no scrub line, and the Dial keeps tuning. *Test: `syncSendsNothingToOldFirmware` (Task 2).*
2. **Turning hard past either end:** the Dial's prediction and SubFloor's seek both clamp to `0…len`. The answering `POS … seq` settles the Dial on the clamped value. *Test: `seekBeyondTheEndAnswersTheClampedPosition` (Task 2); firmware check in Task 5.*
3. **Changing link mid-scrub** (USB unplugged, Bluetooth takes over, so a new `HELLO`): scrub mode resumes on the new link without touching the window. *Test: `helloResendsScrubOn` (Task 2).*
4. **Playback ending, or the file deleted in Finder, while the Dial is extrapolating:** the Dial stops at the end (`PLAY 0` plus `POS`), or goes back to tuning (`SCRUB off`). *Tests: `endOfPlaybackSendsPlayAndPosition` and `targetGoneSendsScrubOff` (Task 2).*
5. **A title with spaces or a newline:** the title stays one line, last on the line, and the Dial shows it whole. *Test: `scrubOnKeepsTheTitleLastAndOnOneLine` (Task 1).*

---

### Task 1: Scrub lines in `DialProtocol`

**Files:**
- Modify: `Sources/SubFloor/Dial/DialProtocol.swift`
- Test: `Tests/SubFloorTests/DialProtocolTests.swift`

**Interfaces:**
- **Produces:**
  - `DialProtocol.Event` cases: `.scrubMove(seq: Int, jumps: Int, jump: Double)`, `.jump(seconds: Double)`, `.playToggle`;
  - `static func scrubOn(startSecondOfDay: Double, length: Double, position: Double, playing: Bool, jump: Double, title: String) -> String`;
  - `static let scrubOff = "SCRUB off"`;
  - `static func position(_ s: Double, seq: Int? = nil) -> String`;
  - `static func playing(_ on: Bool) -> String`;
  - `static func jump(_ s: Double) -> String`;
  - `static func supportsScrub(firmware: String) -> Bool`;
  - `static let version = 2`.

- [ ] **Step 1: Write the failing tests** (add to `DialProtocolTests`)

```swift
@Test func parsesTheScrubEvents() {
    #expect(DialProtocol.parse("J 7 -3 0.5") == .scrubMove(seq: 7, jumps: -3, jump: 0.5))
    #expect(DialProtocol.parse("JUMP 30") == .jump(seconds: 30))
    #expect(DialProtocol.parse("PLAY") == .playToggle)
    #expect(DialProtocol.parse("J 1 2") == nil)
    #expect(DialProtocol.parse("J 1 2 0") == nil, "a zero jump moves nothing")
    #expect(DialProtocol.parse("JUMP -1") == nil)
}

@Test func formatsTheScrubLines() {
    #expect(DialProtocol.scrubOn(startSecondOfDay: 28_092.4, length: 312.456, position: 0, playing: false, jump: 1,
                                 title: "11.175 MHz USB")
            == "SCRUB on t0=28092.40 len=312.46 pos=0.00 play=0 jump=1 title=11.175 MHz USB")
    #expect(DialProtocol.scrubOff == "SCRUB off")
    #expect(DialProtocol.position(12.346) == "POS 12.35")
    #expect(DialProtocol.position(0, seq: 4) == "POS 0.00 4")
    #expect(DialProtocol.playing(true) == "PLAY 1")
    #expect(DialProtocol.jump(0.1) == "JUMP 0.1")
    #expect(DialProtocol.jump(300) == "JUMP 300")
}

@Test func scrubOnKeepsTheTitleLastAndOnOneLine() {
    let line = DialProtocol.scrubOn(startSecondOfDay: 0, length: 1, position: 0, playing: true, jump: 5, title: "6.925 MHz\nAM")
    #expect(line.hasSuffix(" title=6.925 MHz AM"))
    #expect(!line.contains("\n"))
}

@Test func onlyFirmwareFromOneOneKnowsScrub() {
    #expect(!DialProtocol.supportsScrub(firmware: "1.0.0"))
    #expect(DialProtocol.supportsScrub(firmware: "1.1.0"))
    #expect(DialProtocol.supportsScrub(firmware: "1.10.2"))
    #expect(DialProtocol.supportsScrub(firmware: "2.0"))
    #expect(!DialProtocol.supportsScrub(firmware: "?"))
    #expect(!DialProtocol.supportsScrub(firmware: ""))
}
```

Also change the `hello` expectation in `formatsWhatSubFloorSends` to `"HELLO SubFloor 2 host=War's Mac Pro"`.

- [ ] **Step 2:** Run `swift test --filter DialProtocolTests`. Expected: FAIL, because the new members don't exist yet.
- [ ] **Step 3:** Implement the members above in `DialProtocol`.
  - Parse `J` like `T`: three arguments, and the jump > 0.
  - `jump(_:)` uses the shortest decimal: `String(format: "%g", s)`.
  - `supportsScrub` splits on `.`, maps the parts to `Int`, and fails if any part isn't a number. It compares `[major, minor]` against `[1, 1]`.
- [ ] **Step 4:** Run `swift test --filter DialProtocolTests`. Expected: PASS.
- [ ] **Step 5: Commit:** `feat(dial): scrub lines in the dial protocol`.

### Task 2: `DialScrub`, the scrub target and the line sync

**Files:**
- Create: `Sources/SubFloor/Dial/DialScrub.swift`
- Test: `Tests/SubFloorTests/DialScrubTests.swift`

**Interfaces:**
- **Consumes:** Task 1's formatters; `CatalogRecording` (`file`, `start`, `frequencyHz`, `mode`, `inProgress`); `RecordingsCatalog.laneTitle(frequencyHz:mode:)`.
- **Produces:**

```swift
/// What the dial scrubs. nil anywhere means the dial tunes.
struct DialScrubTarget: Equatable {
    var file: String
    var title: String              // "11.175 MHz USB"
    var startSecondOfDay: Double   // UTC seconds since midnight of the recording's start
    var length: Double
    var position: Double
    var playing: Bool
    var jump: Double

    /// The scrub-mode condition from the Global Constraints.
    static func make(windowIsKey: Bool, unplayableFile: String?, playerFile: String?, loadError: String?,
                     duration: Double, position: Double, playing: Bool, jump: Double,
                     recording: CatalogRecording?) -> DialScrubTarget?
}

/// Turns successive targets into the lines that keep the dial's scrub screen right. `now` is monotonic seconds.
struct DialScrubSync {
    /// Lines to send for this target (nil: tune).
    mutating func lines(for target: DialScrubTarget?, now: Double) -> [String]
    /// The answer to the dial's `J <seq> …`, after the player has moved.
    mutating func answer(position: Double, seq: Int, now: Double) -> String
    /// The dial took this jump size itself (`JUMP` from the dial): don't echo it back.
    mutating func dialChose(jump: Double)
    /// After any `HELLO`: the dial has forgotten scrub mode.
    mutating func reset()
}
```

- **What `lines(for:now:)` sends, in order:**
  1. nil after a target → `SCRUB off`.
  2. Turning on, or a different `file` → one `SCRUB on …`. This records the position, time, play state and jump that were sent.
  3. Same file:
     - jump changed → `JUMP j`;
     - `playing` changed → `PLAY x` then `POS p`;
     - otherwise → `POS p` when `|position − expected| > 0.3`, or while playing when 5 s have passed since the last `POS`.

  `expected` = last sent position + (`now` − time it was sent) when playing, capped at `length`.

- [ ] **Step 1: Write the failing tests**

```swift
struct DialScrubTests {
    let rec = CatalogRecording(file: "a.flac", start: Date(timeIntervalSince1970: 1_792_000_000 + 0.4), seconds: 312,
                               frequencyHz: 11_175_000, mode: "USB", auto: true, heard: false, inProgress: false,
                               laneID: "11175000 USB")
    func target(pos: Double = 0, playing: Bool = false, jump: Double = 1) -> DialScrubTarget? {
        .make(windowIsKey: true, unplayableFile: nil, playerFile: "a.flac", loadError: nil, duration: 312,
              position: pos, playing: playing, jump: jump, recording: rec)
    }

    @Test func targetNeedsAKeyWindowAndAPlayableRecording()
    // make(...) is non-nil only for the full condition, with title "11.175 MHz USB" and startSecondOfDay == 1_792_000_000.4 mod 86_400.
    // nil for each of: windowIsKey false; unplayableFile == "a.flac"; playerFile nil or "b.flac"; loadError set;
    // duration 0; recording.inProgress true; recording nil.

    @Test func turningOnSendsScrubOnOnce()
    // lines(for: target(), now: 0) == [scrubOn(...)]; lines(for: target(), now: 0.1) == [].

    @Test func targetGoneSendsScrubOff()
    // after on: lines(for: nil, now: 1) == ["SCRUB off"]; again nil → [].

    @Test func anotherFileSendsScrubOnAgain()

    @Test func jumpAndPlayChangesSendTheirLines()
    // jump 1 → 30: ["JUMP 30"]; playing false → true at pos 3: ["PLAY 1", "POS 3.00"].

    @Test func endOfPlaybackSendsPlayAndPosition()
    // playing at pos 310 (now 0) → stops at pos 312 (now 2): ["PLAY 0", "POS 312.00"].

    @Test func playingSendsPositionOnlyOnDriftOrEveryFiveSeconds()
    // playing from pos 0 at now 0: at now 1 / pos 1.1 → []; at now 2 / pos 2.6 → ["POS 2.60"];
    // at now 7.1 / pos 7.6 → ["POS 7.60"] (5 s since the last POS, no drift).

    @Test func aSeekInTheWindowSendsPosition()
    // paused at 10 → paused at 40: ["POS 40.00"].

    @Test func seekBeyondTheEndAnswersTheClampedPosition()
    // answer(position: 312, seq: 9, now: 1) == "POS 312.00 9", and lines(for: target(pos: 312), now: 1.05) == [].

    @Test func dialChosenJumpIsNotEchoed()
    // dialChose(jump: 5); lines(for: target(jump: 5)) == [].

    @Test func helloResendsScrubOn()
    // on, reset(), lines(for: same target) == [scrubOn(...)].

    @Test func syncSendsNothingToOldFirmware()
    // The controller passes nil for old firmware: lines(for: nil, now:) from a fresh sync == [].
}
```

Write each body as its comment says, with `#expect` on the exact lines from Task 1's formatters.

- [ ] **Step 2:** Run `swift test --filter DialScrubTests`. Expected: FAIL, because the types don't exist yet.
- [ ] **Step 3:** Implement `DialScrubTarget.make` and `DialScrubSync` in `DialScrub.swift`.
- [ ] **Step 4:** Run `swift test --filter DialScrubTests`. Expected: PASS.
- [ ] **Step 5: Commit:** `feat(dial): the scrub target and the lines that keep the dial in step`.

### Task 3: Wire scrub mode into the app

**Files:**
- Modify: `Sources/SubFloor/App/AppModel.swift`, adding the window focus state next to `player`.
- Modify: `Sources/SubFloor/UI/Recordings/RecordingsWindow.swift`
- Modify: `Sources/SubFloor/Dial/DialController.swift`
- Test: `Tests/SubFloorTests/DialScrubTests.swift` (one more test)

**Interfaces:**
- **Consumes:** Tasks 1–2; `RecordingPlayer` (`file`, `loadError`, `duration`, `position`, `isPlaying`, `jump`, `seek(to:)`, `togglePlay()`, `jumpSizes`).
- **Produces:**
  - `AppModel.recordingsWindowIsKey: Bool` (default false);
  - `AppModel.recordingsUnplayableFile: String?` (default nil);
  - `DialController.scrubTarget: DialScrubTarget?`, which is internal and computed from the model, for tests and the controller's tick.

- [ ] **Step 1: Window.** In `RecordingsWindow`, read `@Environment(\.controlActiveState)`.
  - Set `model.recordingsWindowIsKey = (state == .key)` in `.onAppear` and in `.onChange(of: controlActiveState)`; set it to false in `.onDisappear`.
  - Mirror `peaksFailure` into `model.recordingsUnplayableFile` in `.onChange(of: peaksFailure)`, as the failing URL's `lastPathComponent`, or nil.
  - Set it to nil in `.onDisappear`.
- [ ] **Step 2: Controller.**
  - `scrubTarget` = `DialProtocol.supportsScrub(firmware:)` ? `DialScrubTarget.make(...)` from the model, player and `model.library.catalog.recording(player.file)` : nil.
  - In `tick()`, after the existing sends: `for l in scrubSync.lines(for: scrubTarget, now: ProcessInfo.processInfo.systemUptime) { send(l) }`.
  - In the `HELLO` branch, after `sent = SentState()`, call `scrubSync.reset()`.
  - In `apply`:
    - `.scrubMove`: only when `scrubTarget != nil`, `player.seek(to: player.position + Double(jumps) * jump)`, then `send(scrubSync.answer(...))`;
    - `.jump(let s)`: when scrubbing and `RecordingPlayer.jumpSizes.contains(s)`, `player.jump = s` and `scrubSync.dialChose(jump: s)`;
    - `.playToggle`: when scrubbing, `player.togglePlay()`, then send `scrubSync.lines(...)` straight away.
- [ ] **Step 3: Test.** Add `@MainActor @Test func controllerTargetsNothingWithoutAKeyWindow()` to `DialScrubTests`.
  - Use a hermetic `AppModel` (as in `AppModelDialTests.makeModel()`).
  - `DialController(model:defaults:)` (never started) has `scrubTarget == nil` with the window not key.
- [ ] **Step 4:** Run `swift test --filter "DialScrubTests|DialProtocolTests|RecordingsUITests|RecordingPlayerTests"` and `swift build`. Expected: all pass, and the build is clean.
- [ ] **Step 5: Commit:** `feat(dial): the recordings window hands the dial to its player while it is key`.

### Task 4: Firmware protocol, state and gestures

Create branch `scrub` in `/Users/war/Desktop/code/radiodial`.

**Files:**
- Modify: `firmware/src/config.h`
  - `DIAL_FW_VERSION "1.1.0"`;
  - `constexpr float kJumps[] = {0.1f, 0.5f, 1, 5, 30, 300}`;
  - `kJumpCount`;
  - `pal::scrub = 0xFF7AC8`.
- Modify: `firmware/src/app.h`, adding:

```cpp
struct Scrub {
  bool active = false;
  String title;
  float t0 = 0, len = 0;
  float pos = 0;            // at posAtMs
  uint32_t posAtMs = 0;
  bool playing = false;
  uint8_t jumpIdx = 2;      // 1 s
  uint32_t jumpFlashMs = 0;
  uint32_t lastLocalMs = 0; // knob last moved the playhead
  float now() const;        // pos advanced to millis() while playing, within 0…len
};
```

  Add `Scrub scrub;` to `App`.
- Modify: `firmware/src/main.cpp`
- Modify: `PROTOCOL.md`

- [ ] **Step 1: Protocol in** (`processLine`, active link only).
  - `SCRUB on …`: parse `t0`, `len`, `pos`, `play` and `jump` with `field()`. The title is everything after `title=`. Set `active`, `posAtMs = millis()`, and snap the jump to the nearest `kJumps`.
  - `SCRUB off`: set `active = false`.
  - `POS <s> [seq]`: apply the stale-line rules with a separate `scrubSeqSent` and `pendingJumps` (not the tune ones). On acceptance: `pos = s`, `posAtMs = millis()`.
  - `PLAY <0|1>`: freeze `pos = now()` and set `posAtMs`, then `playing`.
  - `JUMP <j>`: snap to the nearest index.
  - In the `HELLO` handler, the `BYE` handler and the host-timeout branch of `loop()`: set `app.scrub.active = false`.
- [ ] **Step 2: Protocol out.**
  - `flushOutgoing()` sends `J <seq> <n> <j>` for pending jumps. If the jump size changed while some were pending, it flushes them first, as `pendingStep` does for tuning.
  - Jump changes send `JUMP <j>`. A tap sends `PLAY`.
  - `<j>` is formatted shortest: `0.1`, `0.5`, `1`, `5`, `30`, `300`.
- [ ] **Step 3: Gestures.** In `handle()`, `Screen::tune` with `app.scrub.active` routes to a new `handleScrub(ev, a, b)` per the Global Constraints table:
  - **Turn:** `pos = clamp(now() + n * jump, 0, len)`, set `posAtMs = millis()` and `lastLocalMs`, add `n` to `pendingJumps`, and turn the bezel by `−6° × n`.
  - **Tap:** predict `playing = !playing`, freezing `pos` first.
  - **Press, hold + turn and swipe:** change `jumpIdx`, set `jumpFlashMs`, and send `JUMP`.
  - Use the same `click()` sounds as the tune equivalents.
- [ ] **Step 4:** `SIM` already routes through `handle()`, so scrub gestures can be simulated with no new debug verbs. Update `PROTOCOL.md`:
  - a "Scrub mode (firmware 1.1.0+)" section with every new line and its meaning;
  - the stale rules and the `title`-last rule;
  - a note that SubFloor sends scrub lines only to ≥ 1.1.0.
- [ ] **Step 5:** Build: `cd /Users/war/Desktop/code/radiodial/firmware && ~/.platformio/penv/bin/pio run`. Expected: `SUCCESS`.
- [ ] **Step 6: Commit (radiodial):** `Scrub mode: protocol, state and gestures (firmware 1.1.0)`.

### Task 5: Firmware scrub screen, and checking it on the device

**Files:**
- Modify: `firmware/src/ui.cpp`
- Create: `SubFloorDial-1.1.0.bin` at the repository root (the release image, as for 1.0.0).

**Layout** (240×240 round; existing fonts only):
- **Ring:** the bezel, plus a progress arc at r = 119 from 0° to `360° × now()/len` in `pal::scrub`, 3 px wide.
- **Title:** `fSmall`, `pal::dim`, y ≈ 58.
- **Clock:** `HH:MM:SS.dZ` in `fFreqBig`, scaled to ≤ 206 px wide like the frequency, baseline 124. Dim the `Z` as the frequency dims its separators.
- **Play state:** a filled ▶ or ❚❚ glyph (≈ 16 px) at y ≈ 92, `pal::scrub` while playing and `pal::dim` while paused.
- **Jump chip:** `drawStepChip`'s pill at y = 152 with label `JUMP`, value as in the Global Constraints, and tint `pal::scrub`. It flashes on `jumpFlashMs` and glows while held, as the step chip does.
- **Bottom line:** `fSmall`, `pal::faint`, y ≈ 182: `Tap to play` or `Tap to pause`.
- `drawStatus()` stays, so the link state is still visible.

`render()` keeps animating while `scrub.active && scrub.playing`, so the clock and ring move.

- [ ] **Step 1:** Implement `drawScrub()` and call it from `render()` for `Screen::tune` when `app.scrub.active`.
- [ ] **Step 2:** Build with `pio run`. Expected: `SUCCESS`.
- [ ] **Step 3: Flash the device.**
  - Quit SubFloor first: it holds the serial port. Check with `pgrep -lf SubFloor.app`.
  - Run `pio run -t upload --upload-port /dev/cu.usbmodem1101`. Use the port that `ls /dev/cu.usbmodem*` shows.
  - The rollback image is `SubFloorDial-1.0.0.bin`.
- [ ] **Step 4: Check on the device** with `python3 firmware/tools/dialctl.py <port> … --shot <scratch>/scrub-N.png`. Expected after each step:
  1. **Greet:** `"HELLO SubFloor 2 host=Test"` replies `HELLO SubFloorDial 1.1.0 …`.
  2. **Enter scrub:** `"SCRUB on t0=28092.40 len=312.00 pos=0.00 play=0 jump=1 title=11.175 MHz USB"` → the shot shows `07:48:12.4Z`, the title, the paused glyph and `JUMP 1 s`.
  3. **Turn:** `"SIM ENC 5"` → the reply contains `J 1 5 1`, and the clock reads `07:48:17.4Z`.
  4. **Press:** `"SIM CLICK"` → `JUMP 5`, and the chip shows `5 s`.
  5. **Swipe:** `"SIM SWIPE 60"` → `JUMP 1`.
  6. **Hold + turn:** `"SIM HOLD 9"` → `JUMP 300`, clamped at 5 min.
  7. **Past the end:** `"SIM ENC 400"` then `"POS 312.00 2"` → the clock shows `07:53:24.4Z`, and the ring is full.
  8. **Tap:** `"SIM TAP 120 120"` → `PLAY`, and the glyph shows playing. Two shots 1 s apart show the clock moving, capped at the end.
  9. **Stale POS:** `"POS 10.00 1"` (stale seq) is ignored.
  10. **Leave scrub:** `"SCRUB off"` → the tune screen is unchanged from 1.0.0.
  11. **Tune regression:** `"SIM ENC 1"` → `T …`.
  12. **Link loss:** `"BYE"` while in scrub → the tune screen comes back.
- [ ] **Step 5:** Copy `.pio/build/m5dial/firmware.bin` to `SubFloorDial-1.1.0.bin`, matching how 1.0.0 was made. If 1.0.0 is a merged full image, read the README and do the same.
- [ ] **Step 6: Commit (radiodial):** `Scrub screen: playhead clock, jump chip and progress ring`. Include the screenshots' description in the commit body, not the images.

### Task 6: End-to-end check with SubFloor

No code. It needs the user's screen unlocked, and the user opens the Recordings window, since there is no input automation on this Mac.

- [ ] **Step 1: Set up.**
  - Back up the defaults: `defaults export app.subfloor.SubFloor <scratch>/defaults-part3.plist`.
  - Set `dialUseUSB` to false so SubFloor talks to the Dial over Bluetooth and `dialctl.py` can use USB for `SIM`/`SHOT`.
  - Build `./scripts/bundle.sh` and launch `build/SubFloor.app`.
- [ ] **Step 2:** The user opens Recordings (⌘⇧L) and selects the 19:46:39Z recording, with the window key. Then:
  - a Dial shot shows the scrub screen;
  - `SIM ENC 3` moves SubFloor's playhead clock by 3 s in a SubFloor window screenshot;
  - `SIM CLICK` lights the window's `5 s` chip;
  - `SIM TAP 120 120` plays, and live audio mutes.
- [ ] **Step 3:** The user clicks the main window, so Recordings loses key: the Dial goes back to tuning. Re-keying Recordings brings scrub back.
- [ ] **Step 4:** Restore the defaults from the backup. Report the results in the ledger.

---

## Self-review notes

- **Spec coverage:**

  | Spec | Where |
  |---|---|
  | §6.1 condition and builder's call (key window + selected) | Global Constraints, Task 3 |
  | §6.1 gestures table | Global Constraints, Task 4 |
  | §6.1 screen contents and ring colour | Task 5 |
  | §6.2 lines | Global Constraints, Tasks 1, 4 |
  | §6.2 prediction and stale `POS` | Task 4 |
  | §6.2 version gating via `HELLO` | Tasks 1, 3 |
  | §6.2 PROTOCOL/firmware/DialProtocol/DialController change together, version bumped | Tasks 1, 3, 4 |
  | §5 jump chips mirrored, and clicking a chip sets it | Task 2 (`JUMP` on change), existing chips |
  | §7 `DialProtocolTests`; device check with `dialctl.py` | Tasks 1, 5 |

- **Builder's calls made here:**
  - `J` carries the jump size, as `T` carries the step, so a jump changed mid-turn can't apply the wrong size.
  - Turning in scrub mode ignores the acceleration setting.
  - Press wraps; hold + turn and swipes clamp.
  - Tap anywhere toggles play.
  - The Dial extrapolates the playhead while playing; SubFloor corrects drift over 0.3 s and resyncs every 5 s.
  - The ring is pink `0xFF7AC8`.
  - The Dial doesn't save the jump size; SubFloor's `player.jump` is the source.
  - SubFloor keeps sending `F`/`M`/`BW`/`SIG` during scrub, so the tune screen is current when scrub ends.
