# Noise Reduction and Skip Silence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Light-to-Strong noise reducer for HF voice, live and in the Recordings player, driven by
one shared NR button; and Skip silence in the player.

**Architecture:**
- **The reducer:** a streaming MMSE-LSA spectral reducer in DSPCore (`SpectralNoiseReducer`, the
  maths) wrapped by `NoiseReducer` (on/off, strength ramps, crossfades, make-up gain). It runs on the
  DSP thread, after the auto recorder takes its audio and before the volume knob.
- **The player** moves from `AVAudioPlayer` to `AVAudioEngine`: an `AVAudioPlayerNode` feeding an
  in-process `AUAudioUnit` effect that runs the same `NoiseReducer`.
- **Skip silence** uses a `SilenceMap` built from the cached waveform peaks. The player's 30 Hz tick
  seeks past silent runs.

**Tech Stack:** Swift 6, SwiftUI, macOS 15, Accelerate (vDSP), AVFoundation (AVAudioEngine,
AUAudioUnit), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-28-noise-reduction-design.md`. Research and listening spike:
`docs/superpowers/research/2026-10-28-noise-reduction-research.md` and
`docs/superpowers/research/2026-10-28-nr-spike.py`.

## Global Constraints

- **NR is off:** the audio is bit-for-bit what it is today, live and in playback.
- **NR never changes:**
  - what is recorded (the audio recorder and Auto's history);
  - the modem channel's audio;
  - the squelch;
  - the signal meter;
  - Auto's trigger.
- **Attenuate only:** per-bin gain ≤ 1 and ≥ the floor. Overall level is kept by the make-up gain,
  which never brings the noise floor back up.
- **No click** on toggling NR or moving the slider. Ramp or crossfade over 30 ms.
- **Latency** under 50 ms.
- **No allocation, locks or Swift concurrency on the DSP thread or the render thread.** Settings
  cross threads without blocking.
- **NR is offered in AM, NFM, USB, LSB and CW.** In WFM the button is disabled and NR is bypassed;
  the setting is kept.
- **One shared setting** (on/off + strength), saved between launches. It starts off at Medium
  (strength 0.5).
- **Skip silence** is saved between launches and starts on.
- **No GPL or LGPL code.** Don't port WDSP or libspecbleach.
- **Copy:**
  - the button reads `NR` when off and `NR · Light|Medium|Strong` when on;
  - the slider ends are labelled `Light` and `Strong`;
  - the WFM tooltip reads `Noise reduction is for voice; it's off in WFM`;
  - the toggle reads `Skip silence`.

## Review Focus

1. **Squelch-gated silence live.** The gate closes for seconds, then opens on hiss and voice. NR must
   come straight back at full reduction, not pass raw hiss while it re-learns the noise. (Task 1 test
   `noiseEstimateSurvivesDigitalSilence`.)
2. **A static crash.** A 200 ms burst 20 dB over the hiss must not leave the voice ducked afterwards.
   (Task 1 test `aCrashDoesNotDuckTheVoiceAfterIt`.)
3. **A strong, clean voice.** It must come through essentially unchanged at every strength. (Task 2
   test `aStrongToneIsNotColoured`.)
4. **The output device going away mid-playback.** The engine stops: the player must pause where it
   was and unmute the live radio, as it does today. (Task 6 test `anEngineThatStopsUnmutes`.)
5. **Seeking while playing.** Stopping the old segment fires its completion handler, and that must
   not end playback or move the position to the end. (Task 6 test `seekingWhilePlayingKeepsPlaying`.)

---

### Task 1: The spectral reducer

**Files:**
- Create: `Sources/DSPCore/SpectralNoiseReducer.swift`
- Test: `Tests/DSPCoreTests/NoiseReducerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public final class SpectralNoiseReducer {
      public static let frameSize = 1024          // at 48 kHz
      public static let hop = 256
      public init(sampleRate: Double = 48_000)
      /// 0 Light … 1 Strong. Read at each frame.
      public var strength: Double
      public static func floorDb(strength: Double) -> Float      // -(8 + 12·s): -8, -14, -20
      public static func overEstimate(strength: Double) -> Float // 1 + s: 1.0, 1.5, 2.0
      /// Samples by which the output lags the input.
      public var latency: Int { get }
      /// In place, any count; output delayed by `latency`.
      public func process(_ buffer: UnsafeMutableBufferPointer<Float>)
      /// Smoothed (time constant about 1 s) level drop, in dB (≥ 0), that the reducer applied on
      /// speech frames. 0 until a speech frame is seen.
      public private(set) var voiceLossDb: Float
      public func reset()
  }
  ```

The algorithm is the spike's `mmse_lsa`; reproduce it, in streaming form:
- STFT with √Hann (periodic) analysis and synthesis, frame 1024, hop 256, overlap-add normalised.
- Power P; noise tracker; a-posteriori SNR γ = P/(N·β) with β = `overEstimate`.
- Decision-directed a-priori SNR ξ = 0.98·prevClean/N + 0.02·max(γ−1, 0), floored at −25 dB.
- LSA gain G = ξ/(1+ξ)·exp(½·E1(v)), with v = ξ/(1+ξ)·γ, clamped to [floor, 1].
- E1 by Abramowitz & Stegun as in the spike, vectorised with vDSP/vForce.

The noise tracker is the spike's: power smoothed with α = 0.85 per frame, then the minimum over 1.5 s
(281 frames), × 1.8. Implement the minimum with 8 sub-windows (Martin 2001), so the cost per frame is
O(bins).

Two rules the spike lacked:
- **Digital silence:** a frame whose mean input power is below 1e-8 (−80 dBFS) doesn't update the
  tracker or the a-priori state, and outputs its input.
- **No divide-by-zero:** the noise estimate is floored at 1e-12.

A **speech frame** has mean γ over the bins for 300–3000 Hz above 4 (6 dB). `voiceLossDb` tracks
10·log10(input power / output power) over speech frames only.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func latencyIsReportedExactly()                 // an impulse comes out exactly `latency` samples later (±1)
@Test func gainNeverAmplifies()                       // white noise + tones, every strength: output RMS per 0.1 s ≤ input RMS + 0.1 dB
@Test func whiteNoiseIsReducedByAboutTheFloor()       // 5 s white noise at -20 dBFS; last 3 s output level vs input:
                                                      //   strength 0: -6…-10 dB, 0.5: -11…-16 dB, 1: -16…-22 dB
@Test func aVoiceLikeToneAboveTheNoisePasses()        // 1 kHz tone 15 dB over white noise, strength 0.5:
                                                      //   tone bin level within 1.5 dB of input (Goertzel at 1 kHz)
@Test func digitalSilenceGivesSilenceAndNoNaNs()      // 2 s zeros: output all zeros, no NaN/inf anywhere
@Test func noiseEstimateSurvivesDigitalSilence()      // 3 s noise, 5 s zeros, 3 s same noise: reduction over
                                                      //   0.0–0.5 s after the gap within 2 dB of the reduction just before it
@Test func aCrashDoesNotDuckTheVoiceAfterIt()         // tone 15 dB over noise; 200 ms burst of noise +20 dB at t = 3 s:
                                                      //   tone level over 3.5–4.0 s within 1 dB of 2.5–3.0 s
@Test func voiceLossIsMeasuredOnSpeechFramesOnly()    // noise only: voiceLossDb stays 0; tone over noise: 0 < voiceLossDb < 6
@Test func floorAndOverEstimateMapping()              // floorDb(0)=-8, (0.5)=-14, (1)=-20; overEstimate(0)=1, (0.5)=1.5, (1)=2
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter NoiseReducerTests`. Expected: build failure, `SpectralNoiseReducer` not found.

- [ ] **Step 3: Implement `SpectralNoiseReducer`** as above, with preallocated buffers and vDSP FFTs.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test --filter NoiseReducerTests`. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/DSPCore/SpectralNoiseReducer.swift Tests/DSPCoreTests/NoiseReducerTests.swift
git commit -m "feat(nr): streaming MMSE-LSA spectral noise reducer"
```

### Task 2: The NR control: settings, bypass, ramps and make-up gain

**Files:**
- Create: `Sources/DSPCore/NoiseReducer.swift`
- Test: `Tests/DSPCoreTests/NoiseReducerTests.swift` (append)

**Interfaces:**
- Consumes: `SpectralNoiseReducer` (Task 1).
- Produces:
  ```swift
  public struct NoiseReductionSettings: Codable, Equatable, Sendable {
      public var enabled: Bool          // default false
      public var strength: Double       // 0...1, default 0.5
      public init(enabled: Bool = false, strength: Double = 0.5)
      public var label: String          // "Light" < 1/3 ≤ "Medium" ≤ 2/3 < "Strong"
      public static func isAvailable(for mode: DemodMode) -> Bool   // false only for .wfm
  }
  public final class NoiseReducer {
      public init(sampleRate: Double = 48_000)
      /// Call on the processing thread only.
      public func update(_ settings: NoiseReductionSettings)
      public func process(_ buffer: UnsafeMutableBufferPointer<Float>)   // in place
      public func reset()
  }
  ```

**Behaviour:**
- **Disabled and settled:** `process` returns at once and touches nothing (bit-exact).
- **Enabling:** crossfade dry → wet over 30 ms (1440 samples). Disabling crossfades wet → dry. During
  either fade the spectral reducer runs. The dry and wet paths differ by `latency`, which is accepted.
- **Strength changes** ramp the reducer's `strength` to the new value over 30 ms (or step it once per
  hop).
- **Make-up gain:**
  - makeupDb = clamp(`voiceLossDb`, 0, max(0, −floorDb − 6)); the limit is 2, 8 and 14 dB at
    strength 0, 0.5 and 1;
  - applied to the wet path and smoothed per sample (time constant 200 ms);
  - `reset()` returns it to 0.
- **`reset()`** clears the reducer state and the make-up gain, and keeps the settings.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func offIsBitExact()                    // random buffer through a fresh NoiseReducer (disabled): identical bytes
@Test func offAfterOnSettlesToBitExact()      // enable, 1 s, disable, 0.1 s, then a buffer: identical bytes
@Test func togglingHasNoStep()                // steady tone + noise; across the toggle point, the largest
                                              //   sample-to-sample difference ≤ 1.5× the largest elsewhere
@Test func makeUpKeepsTheVoiceLevel()         // tone 6 dB over noise, strength 0.5, after 3 s:
                                              //   tone level within 2 dB of the input's
@Test func makeUpNeverLiftsTheNoiseBack()     // noise only, every strength, after 3 s:
                                              //   output level ≤ input level − 5 dB (strength 0: ≤ −5; 0.5: ≤ −10; 1: ≤ −15)
@Test func aStrongToneIsNotColoured()         // tone 30 dB over noise, strengths 0, 0.5, 1: tone level within 0.5 dB
@Test func labelsAndAvailability()            // label 0.2 "Light", 0.5 "Medium", 0.9 "Strong";
                                              //   available for am,nfm,usb,lsb,cw, not wfm
@Test func settingsRoundTrip()               // JSON-encode {enabled: true, strength: 0.7}, decode: equal
```

- [ ] **Step 2: Run them to see them fail.** `swift test --filter NoiseReducerTests`: build failure.
- [ ] **Step 3: Implement** `NoiseReductionSettings` and `NoiseReducer`.
- [ ] **Step 4: Run them to see them pass.** `swift test --filter NoiseReducerTests`: all pass.
- [ ] **Step 5: Commit** `feat(nr): on/off, strength ramps and make-up gain around the reducer`.

### Task 3: A listening and measuring tool

**Files:**
- Create: `Sources/NRCheck/main.swift`
- Modify: `Package.swift`: add
  `.executableTarget(name: "NRCheck", dependencies: ["DSPCore"], swiftSettings: fastMath)`.

**Interfaces:**
- Consumes: `NoiseReducer`, `NoiseReductionSettings` (Task 2).

What it does:
- `swift run -c release NRCheck <audio file> <start s> <seconds> <out dir>` reads any file AVFoundation
  can read (FLAC included), mono at 48 kHz.
- It writes `original.wav` and `light.wav`, `medium.wav`, `strong.wav` (strength 0, 0.5, 1). Each is
  16-bit PCM, peak-normalised to 0.7 like the spike.
- For each output it prints the spec's voice-above-hiss measure, in exactly the spec's §6 definition:
  - 0.1 s frames;
  - flatness over FFT bins 30–250 of a Hann-windowed 4800-point frame;
  - voice frames have flatness < 0.25 and hiss frames > 0.5, both chosen from the original;
  - the score is the mean frame dB over voice frames minus the mean over hiss frames.

- [ ] **Step 1: Write the tool.**
- [ ] **Step 2: Run it on the owner's clip.**
  ```bash
  swift run -c release NRCheck ~/Music/SubFloor/SubFloor_20261028_164538Z_11175000Hz_USB.flac 24 32 /tmp/nrcheck
  ```
  Expected:
  - the original scores about 2.5 dB (the spike got 2.5);
  - medium scores within about 1 dB of 9.7 or better.

  Record the four scores in the report. If medium lands outside that, say so and say why. Don't change
  the Task 1 constants to chase the number without saying so.
- [ ] **Step 3: Commit** `feat(nr): NRCheck, a tool to hear and measure the reducer on a recording`.

### Task 4: NR on the live radio

**Files:**
- Modify: `Sources/SubFloor/Engine/DSPEngine.swift` (`Pending`, `update(...)`, the `run` loop's
  audio section)
- Modify: `Sources/SubFloor/App/AppModel.swift` (`SessionState`, state, persistence, mode rule)
- Modify: `Sources/SubFloor/App/SubFloorApp.swift` (Radio menu)
- Test: `Tests/SubFloorTests/NoiseReductionControlTests.swift`

**Interfaces:**
- Consumes: `NoiseReducer`, `NoiseReductionSettings` (Task 2).
- Produces:
  - `DSPEngine.update(noiseReduction: NoiseReductionSettings)`, which delivers the setting through
    `Pending`;
  - `AppModel.noiseReduction: NoiseReductionSettings` (read-write, persisted);
  - `AppModel.noiseReductionAvailable: Bool` (`isAvailable(for: mode)`);
  - `AppModel.toggleNoiseReduction()`.

**Engine:**
- The DSP thread owns one `NoiseReducer`. In the audio section, run it on `audioOut`:
  - after `autoRecorder.process(...)`;
  - before the volume multiply and `vvtanhf`.
- When a receiver config arrives whose `mode` or `bandwidthHz` differs from the current one, call
  `reducer.reset()`. A retune alone doesn't reset.
- The engine is sent the **effective** setting: `enabled && noiseReductionAvailable`. Like the
  volume, the engine keeps the last setting it was sent, and `start(...)` begins with it, so NR set
  while the radio is stopped applies when it runs.

**Model:**
- `noiseReduction` `didSet`: push the effective setting to the engine, set
  `player.noiseReduction = noiseReduction` (Task 6 adds the property; until then skip that line) and
  save the session.
- `setMode` re-pushes the effective setting.
- `SessionState` gains `var noiseReduction: NoiseReductionSettings?`, optional so older sessions
  decode.
- Menu: in the Radio menu, after the auto-record item, add
  `Button(model.noiseReduction.enabled ? "Turn Noise Reduction Off" : "Turn Noise Reduction On")`
  with `.keyboardShortcut("n", modifiers: [.command, .shift])`, disabled when not available.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func noiseReductionIsSavedAndRestored()       // set enabled, strength 0.8; a new AppModel on the same defaults
                                                    //   (the AutoRecordControlTests pattern) has the same settings
@Test func olderSessionsStartWithNROffAtMedium()    // defaults with a session saved before this field: enabled false, strength 0.5
@Test func wfmMakesItUnavailableButKeepsTheSetting() // enabled; setMode(.wfm): noiseReductionAvailable false,
                                                    //   noiseReduction.enabled still true; setMode(.usb): available again
@Test func theEngineGetsTheEffectiveSetting()       // DSPEngine(audioSink:) as in ModemWorkerTests, IQ of a tone in noise;
                                                    //   NR on in USB: speaker audio differs from NR off;
                                                    //   NR on in WFM: identical to NR off
@Test func recordingsDoNotGetNR()                   // NR on, strength 1: the audio recorder's pushed samples equal those with NR off
```

- [ ] **Step 2: Run them to see them fail.** `swift test --filter NoiseReductionControlTests`: build failure.
- [ ] **Step 3: Implement** the engine, model and menu changes.
- [ ] **Step 4: Run them to see them pass,** plus `swift test --filter AutoRecord` and
  `--filter ModemWorker`: all pass.

  Then bundle and run the app on the RSP1B at its highest sample rate, with NR on Strong, for a
  minute. The status bar's dropped-samples count must not rise and the waterfall must not stutter.
  Report what you saw.
- [ ] **Step 5: Commit** `feat(nr): noise reduction on the live radio, saved with the session`.

### Task 5: The NR button, in the main window

**Files:**
- Create: `Sources/SubFloor/UI/NoiseReductionButton.swift`
- Modify: `Sources/SubFloor/UI/TopBarView.swift` (after the HamItUp button)

**Interfaces:**
- Consumes: `AppModel.noiseReduction`, `noiseReductionAvailable`, `toggleNoiseReduction()` (Task 4).
- Produces:
  ```swift
  struct NoiseReductionButton: View {
      @Binding var settings: NoiseReductionSettings
      var available: Bool
  }
  ```
  It is the one component both windows use (Task 8 puts it in the player).

**Look and behaviour** (spec §3.3, mockup B):
- **The button:**
  - a rounded chip styled like the HamItUp button: green fill and black text when on, dimmed outline
    when off;
  - its title is `NR` when off and `NR · <label>` when on, with the `sparkles` SF Symbol;
  - a click toggles `enabled`.
- **The chevron:** a small `chevron.down` segment at the chip's right end. Clicking it, or
  right-clicking anywhere on the chip, opens a popover with:
  - the title `Noise reduction`;
  - the current label;
  - a `Slider(value: strength, in: 0...1)`;
  - `Light` and `Strong` under the slider's ends.

  Moving the slider doesn't turn NR on.
- **Unavailable (WFM):** the chip is disabled (40 % opacity) and its tooltip is the copy in Global
  Constraints.
- **Tooltips otherwise:** `Noise reduction on (⌘⇧N)` and `Noise reduction off (⌘⇧N)`.
- The chip uses fixed colours (green `Color.green`, black text), not the window's accent colour, so it
  looks the same in the dark Recordings window.

- [ ] **Step 1: Add the view and put it in the top bar.**
- [ ] **Step 2: Build and run the app.** `./scripts/bundle.sh && open build/SubFloor.app`. Check:
  - the chip toggles;
  - the popover slider changes the label;
  - ⌘⇧N toggles;
  - WFM greys it out.

  Take a screenshot of the top bar with the popover open for the report. (The screen must be
  unlocked; see the test-rig notes.)
- [ ] **Step 3: Commit** `feat(nr): the NR button and strength pop-up in the top bar`.

### Task 6: The player on AVAudioEngine, with NR

**Files:**
- Create: `Sources/SubFloor/App/NoiseReductionAudioUnit.swift`
- Modify: `Sources/SubFloor/App/RecordingPlayer.swift`
- Modify: `Tests/SubFloorTests/RecordingPlayerTests.swift`

**Interfaces:**
- Consumes: `NoiseReducer`, `NoiseReductionSettings` (Task 2).
- Produces:
  - `RecordingPlayer.noiseReduction: NoiseReductionSettings`, set by `AppModel` (re-enable the line
    from Task 4);
  - the effect applies `enabled && isAvailable(for: the loaded recording's mode)`, where the mode is
    `DemodMode(rawValue: recording.mode.lowercased())` and an unknown mode counts as unavailable;
  - `RecordingPlayer.engine: AVAudioEngine` (internal, for tests, replacing `audio`).

**Design:**
- `NoiseReductionAudioUnit: AUAudioUnit`:
  - an in-process effect registered once with `AUAudioUnit.registerSubclass`, with its own component
    description (type `aufx`, subtype `snrd`, manufacturer `SubF`);
  - one mono float input bus and one output bus;
  - its `internalRenderBlock` pulls input and runs a `NoiseReducer` in place;
  - settings reach it without blocking: for example an `Atomic<UInt64>` holding the enabled bit and the
    strength as fixed-point, read once per render;
  - `reset()` on load.
- **Graph:** `AVAudioPlayerNode → AVAudioUnitEffect(NR) → mainMixerNode`. The format is the file's
  processing format; a non-mono file is mixed to mono by connecting with a mono format.
- **Load:** open `AVAudioFile` (failure gives `loadError = cannotPlay`, as today); duration =
  length / sampleRate; reset the reducer. Only load resets it: seeks and pauses keep its noise
  estimate, so a seek neither blasts raw hiss nor swallows the next words.
- **Play and seek:**
  - play: `scheduleSegment(file, startingFrame: position·rate, frameCount: rest)`, then `play()`, then
    start the engine if needed;
  - seek while playing: `stop()`, reschedule from the new frame, `play()`;
  - a generation counter, captured by each segment's completion handler
    (`.dataPlayedBack`), makes handlers from stopped segments do nothing;
  - a segment that plays to its end calls `finished(successfully: true)` on the main actor.
- **Position:** while playing, `segmentStartFrame + playerTime(forNodeTime: lastRenderTime).sampleTime`,
  over the rate, clamped to the duration. It's read in the existing 30 Hz tick.
- **Volume:** `mainMixerNode.outputVolume = volume`.
- **The engine stopping by itself** (`AVAudioEngineConfigurationChange`, or the engine found not
  running in the tick) works like today's "stopped without saying so": pause at the last position and
  unmute live.
- **Unchanged:** heard marks, live muting, `reconcile`, and the in-progress refusal behave exactly as
  today.

- [ ] **Step 1: Adapt and add tests**

Adapt:
- `aPlayerThatStopsWithoutSayingSoUnmutes` → `anEngineThatStopsUnmutes`: call `p.engine.stop()` behind
  the player's back; after the next tick, `isPlaying == false`, live unmuted, position kept.
- Every other existing test passes unchanged.

Add:

```swift
@Test func seekingWhilePlayingKeepsPlaying()   // play, seek to 50 %: still playing, position ≥ 50 %, not at the end
@Test func positionFollowsAFileOfKnownLength() // 2 s WAV: after play and ~0.5 s, position is within 0.5±0.15 s
@Test func nrSettingReachesTheEffect()         // load a USB recording, set noiseReduction enabled: the unit's
                                               //   effective setting is enabled; a WFM recording: not
@Test func playbackThroughNRIsQuieterOnNoise() // offline: the engine in manual rendering mode (.offline),
                                               //   a 3 s white-noise WAV, NR on at strength 1: rendered RMS of
                                               //   the last second ≥ 10 dB below NR off
```

- [ ] **Step 2: Run them to see them fail.** `swift test --filter RecordingPlayerTests`: the new tests
  fail.
- [ ] **Step 3: Implement** the audio unit and the player changes.
- [ ] **Step 4: Run them to see them pass.** `swift test --filter RecordingPlayer` and
  `--filter DialScrub`: all pass.
- [ ] **Step 5: Commit** `feat(nr): the player plays through AVAudioEngine with the noise reducer`.

### Task 7: The silence map

**Files:**
- Create: `Sources/Recording/SilenceMap.swift`
- Test: `Tests/RecordingTests/SilenceMapTests.swift`

**Interfaces:**
- Consumes: `WaveformPeaks` (existing: `binsPerSecond = 100`, `peaks: [UInt8]`, `duration`).
- Produces:
  ```swift
  public struct SilenceMap: Equatable, Sendable {
      public static let minimumGap = 0.25      // seconds
      public static let landingMargin = 0.2    // seconds
      public init(peaks: WaveformPeaks)
      /// Silent runs in seconds, each ≥ minimumGap, sorted.
      public let runs: [Range<Double>]
      public let duration: Double
      /// Where to skip to from `position`: nil if not in a run or nothing is gained (< 0.05 s);
      /// `run.upperBound - landingMargin`; or `duration` when the run reaches the end.
      public func skipTarget(from position: Double) -> Double?
  }
  ```

A bin is silent when its peak is 0. Runs are maximal stretches of silent bins, with each bin
0.01 s long.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func findsRunsAtLeastAQuarterSecond()   // peaks: 100 loud, 30 silent, 50 loud, 20 silent, 100 loud
                                              //   → runs == [1.0..<1.3]  (the 0.2 s gap is not a run)
@Test func skipTargetLandsBeforeTheAudio()    // run 1.0..<3.0: from 1.0 → 2.8; from 2.0 → 2.8;
                                              //   from 2.78 → nil; from 0.5 → nil
@Test func trailingSilenceSkipsToTheEnd()     // 1 s loud then 2 s silent: from 1.5 → 3.0 (duration)
@Test func allSilentAndNeverSilent()          // all-silent 2 s: from 0 → 2.0; never silent: runs empty, nil everywhere
```

- [ ] **Step 2: Run them to see them fail.** `swift test --filter SilenceMapTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them to see them pass.**
- [ ] **Step 5: Commit** `feat(playback): the silence map, from the waveform peaks`.

### Task 8: Skip silence, and NR in the player

**Files:**
- Modify: `Sources/SubFloor/App/RecordingPlayer.swift`
- Modify: `Sources/SubFloor/App/AppModel.swift` (`SessionState.skipSilence: Bool?`, state, mirroring)
- Modify: `Sources/SubFloor/UI/Recordings/PlayerPanel.swift` (transport row; hand the peaks to the
  player)
- Test: `Tests/SubFloorTests/RecordingPlayerTests.swift`, `Tests/SubFloorTests/NoiseReductionControlTests.swift`

**Interfaces:**
- Consumes: `SilenceMap` (Task 7), `NoiseReductionButton` (Task 5), the Task 6 player.
- Produces:
  - `RecordingPlayer.skipSilence: Bool`;
  - `RecordingPlayer.setPeaks(_ peaks: WaveformPeaks, for file: String)`, which builds the map if
    `file` is the loaded one and is ignored otherwise; unload clears the map;
  - `AppModel.skipSilence: Bool` (default true, persisted), mirrored to the player.

**Behaviour** (spec §4):
- In `tick()`, while playing with `skipSilence` on: if `map.skipTarget(from: position)` gives `t`, then
  `t >= duration` finishes playback as if the file ended, and otherwise `seek(to: t)`.
- In `play()`, the same check runs before playing, so Play in a silent stretch jumps ahead, and Play in
  trailing silence ends at once.
- Paused seeks (click, drag, arrows, Dial) never skip.
- With no map yet (the peaks are still loading), nothing is skipped.

**Transport row:**
- At the right end of the row: `NoiseReductionButton` bound to `model.noiseReduction`, with
  `available` from the loaded recording's mode.
- Then a `Skip silence` toggle chip in the same style: green when on, `forward.end` symbol, tooltip
  `Skip silent stretches while playing`.
- The hint text after them stays and truncates as today.

**Peaks:** where `PlayerPanel` receives the loaded file's peaks, it calls `player.setPeaks`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func skipSilenceJumpsAGapWhilePlaying()     // WAV: 1 s tone, 2 s zeros, 1 s tone; setPeaks; play;
                                                  //   once position passes 1.0, within 0.3 s it is ≥ 2.75
@Test func pausedSeeksIntoSilenceStay()           // paused, seek(to: 1.5): position stays 1.5 after 0.3 s of ticks
@Test func playInSilenceJumpsAhead()              // paused at 1.5, play(): position ≥ 2.75 at once
@Test func trailingSilenceEndsPlayback()          // 1 s tone, 2 s zeros: play from 1.2 → finished, position == duration, live unmuted
@Test func skipOffPlaysThroughSilence()           // skipSilence false: position passes 2.0 normally
@Test func skipSilenceIsSavedAndStartsOn()        // fresh defaults: true; set false; new AppModel: false
```

- [ ] **Step 2: Run them to see them fail.** `swift test --filter RecordingPlayerTests` and
  `--filter NoiseReductionControlTests`.
- [ ] **Step 3: Implement** the player logic, model state and transport row.
- [ ] **Step 4: Run them to see them pass.** Then bundle and run the app. In the Recordings window,
  check:
  - NR and Skip silence on the transport row match the main window's button;
  - a recording with squelch gaps plays straight through.

  Take a screenshot of the transport row.
- [ ] **Step 5: Commit** `feat(playback): Skip silence, and the NR button in the player`.

### Task 9: README

**Files:**
- Modify: `README.md`: in the *Using it* table, add a row
  `| Noise reduction | Top-bar NR (⌘⇧N); its pop-up sets Light to Strong. Also in the Recordings player |`.
  In *Recordings window*, add a row
  `| Skip silence | Jump silent stretches while playing (on by default) |`, and one sentence: NR acts
  only on what you hear, never on what is recorded or decoded.

- [ ] **Step 1: Edit.**
- [ ] **Step 2: Run the full suite in the background,** under `caffeinate -i swift test`. Expected: all
  pass, except the known load-sensitive `classifierCost` timing test, which must pass when run alone.
- [ ] **Step 3: Commit** `docs: noise reduction and Skip silence in the README`.
