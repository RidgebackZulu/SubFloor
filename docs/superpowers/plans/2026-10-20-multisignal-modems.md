# Multi-signal Modems Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decode every CW, PSK31, RTTY, FT8 and WSPR signal inside a draggable 3 kHz modem box at once, with a cursor-locked analysis bench and elegant per-signal output rows.

**Architecture:**
- On the existing DSP thread, a `ModemChannel` turns IQ into 12 kHz USB audio for the box and hands it to a dedicated modem thread through an SPSC ring.
- On that thread, a headless `ModemEngine` (in the `Modems` module) runs:
  - the `SignalTracker`
  - per-signal streaming decoders (CW, PSK31, RTTY)
  - the auto-detect classifier
  - the cursor bench and listen audio
  - a UTC `SlotRecorder` that hands FT8 (vendored ft8_lib) and WSPR (fresh Swift) slots to a background queue
- The app adds the box and cursor to the spectrum and replaces the modem panel. A pure `DecodeLog` drives the rows.

**Tech Stack:** Swift 6, Accelerate/vDSP, Synchronization, SwiftUI Canvas, ft8_lib (C, MIT) as a SwiftPM C target, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-20-multisignal-modems-design.md` (also read the phase-1 spec `docs/superpowers/specs/2026-10-19-subfloor-design.md` for project conventions).

## Global Constraints

- **Platform and threading:**
  - Swift 6 strict concurrency.
  - macOS 15 deployment, Apple Silicon.
  - No locks or allocation on the IQ callback or the audio render path.
  - All decoding runs off the DSP thread: on the modem thread, or the slot queue for FT8 and WSPR.
- **Audio:**
  - Box audio is 12 kHz real USB.
  - The box covers RF `dial+300 … dial+3300` Hz.
  - A subcarrier's audio frequency is `RF − dial`.
- **SNR** in tests and readouts is measured in a 2.5 kHz noise bandwidth (WSJT convention).
- **Modes:** PSK31 (BPSK31 + QPSK31), RTTY (45.45 Bd, 170 Hz shift), CW, FT8 (15 s slots at :00/:15/:30/:45 UTC) and WSPR (2-min slots on even UTC minutes).
- **Concurrency limits:** at most 40 concurrent streaming decoders. The cursor's signal is always decoded.
- **Listen filters:** PSK31 150 Hz, RTTY 400 Hz, CW 250 Hz, FT8 100 Hz, WSPR 50 Hz.
- **Signal lifetime:** a track is quiet after 20 s without energy and removed after 120 s.
- **Licensing:**
  - Vendor ft8_lib (MIT) with its LICENSE file and pinned commit.
  - No GPL code anywhere. Write WSPR from the public protocol description, never from WSJT-X or wsprd source.
- **Live radio only:** FT8 and WSPR run only on live sources (RSP1B or Demo). They are disabled for IQ-file sources, with the panel message "FT8/WSPR need a live radio".
- **CPU:** under 30% of one core for the whole process, release build, 2 MSPS, FFT 8192, with 30 active PSK31 decoders plus FT8.
- **Shortfalls:** never weaken a decode test. If a target can't be met, record the achieved threshold and flag it in the report.
- **Commits** end with the Co-Authored-By trailer that the authoring agent's harness instructs.

## Review Focus

1. **A strong signal next to a weak one** (30 dB apart, 60 Hz apart), and PSK31's ±15.6 Hz sidebands. These must not spawn extra or duplicate tracks, and the weak signal must still be tracked. Covered in Task 4.
2. **A slowly drifting signal** (1 Hz/s over 30 s) keeps the same track id and stays decoded, because AFC follows it. Covered in Tasks 4 and 6.
3. **Moving the box mid-decode** clears tracks, decoders and rows. Old text must never appear under a new frequency. Covered in Tasks 9 and 13.
4. **A gap in the audio inside a slot** (engine restart or overflow) must skip that slot, not decode a partial one. Covered in Task 10.
5. **A hardware retune or sample-rate change while the modem is active.** The box goes inactive when it is outside the captured span and resumes when it is back. The channel is rebuilt with no stale audio. Covered in Tasks 1 and 15.

## File map

```
Sources/DSPCore/FractionalResampler.swift        windowed-sinc arbitrary-ratio resampler
Sources/DSPCore/ModemChannel.swift               IQ → 12 kHz USB box audio
Sources/SubFloorCore/ModemBox.swift              box geometry / RF↔audio maths
Sources/CFT8/…                                   vendored ft8_lib (C) + module map
Sources/Modems/Framework/ModemTypes.swift        ModeID, settings, events, protocols, ModemCatalog
Sources/Modems/Framework/DecodeLog.swift         row store (ordering, quiet, holds, FT8/WSPR log)
Sources/Modems/Tracking/SignalTracker.swift      FFT peaks → tracks
Sources/Modems/Tracking/SignalClassifier.swift   auto-detect
Sources/Modems/CW/CWModem.swift                  multi-signal CW decoder (wraps CWDecoderCore)
Sources/Modems/PSK31/{Varicode,PSK31Decoder,PSK31Encoder,QPSKViterbi}.swift
Sources/Modems/RTTY/{Baudot,RTTYDecoder,RTTYEncoder}.swift
Sources/Modems/FT8/{FT8Modem,FT8Encoder}.swift   Swift wrapper over CFT8
Sources/Modems/WSPR/{WSPRCodec,WSPRFano,WSPREncoder,WSPRDecoder}.swift
Sources/Modems/Engine/{ModemEngine,CursorAnalyzer,SlotRecorder}.swift
Sources/SubFloor/Engine/{ModemWorker,ModemStores,ClockCheck}.swift
Sources/SubFloor/UI/Modem/{ModemPanelView,ModemControlStrip,CursorBenchView,SignalRowsView}.swift
Tests/ModemsTests/Support/ModemTestSignals.swift (AWGN, accuracy metric, synth helpers)
```

Removed in Task 16:
- `Sources/Modems/Modem.swift`, the phase-1 `Modem`, `ModemRegistry` and `ModemHost`
- `Sources/Modems/CW/CWDecoderModem.swift`
- `Sources/SubFloor/UI/ModemPanelView.swift`, the old panel

---

### Task 1: FractionalResampler and ModemChannel

**Files:**
- Create: `Sources/DSPCore/FractionalResampler.swift`, `Sources/DSPCore/ModemChannel.swift`
- Test: `Tests/DSPCoreTests/ModemChannelTests.swift`

**Interfaces:**
- Consumes: `NCO`, `ComplexDecimator`, `FIRDesign`, `DecimationPlan`, `FIRDecimator` (DSPCore). `TestSignals` (in DSPCoreTests).
- Produces:
  - `public struct FractionalResampler: Sendable`
    - `init(inputRate: Double, outputRate: Double, taps: Int = 32)`
    - `mutating func process(_ x: UnsafeBufferPointer<Float>, into out: inout [Float])`
  - `public final class ModemChannel: @unchecked Sendable`
    - `static let outputRate = 12_000.0`
    - `init(inputRate: Double, dialOffsetHz: Double)`, where `dialOffsetHz` is the box dial minus the capture centre, in Hz
    - `func setDialOffset(_ hz: Double)`, which retunes the NCO only
    - `func process(_ iq: UnsafeBufferPointer<DSPComplex>, audio: inout [Float])`, which appends 12 kHz audio

- [ ] **Step 1: Write the failing tests.**

  `upperSidebandToneAppearsAtAudioFrequency`
  - Input: 2 MSPS IQ with a tone at offset `dial+1000`, where the dial offset is 50 kHz, so the tone is at +51 kHz.
  - Expect: after 0.5 s, the output at 12 kHz is dominated by 1000 Hz, using `TestSignals.dominates`, over the probes 500, 1500 and 2000.

  `lowerSidebandIsRejected`
  - Input: a tone at `dial−1000`.
  - Expect: its 1000 Hz power is at least 40 dB below the USB case.

  `outputRateIsExactly12k`
  - Input: 2 s of input at 2 MSPS.
  - Expect: an output count of 24 000 ± 12.

  `passbandCovers300To3300`
  - Expect: tones at 300 and 3300 Hz audio are within 1 dB of a 1500 Hz tone.

  `fractionalResamplerPreservesTone`
  - Input: a 1 kHz tone at 31 250 Hz, resampled to 12 000 Hz.
  - Expect: the result is dominated by 1 kHz, and its count is within ±2 of the ideal.

  `retuneDoesNotRebuild`
  - Expect: `setDialOffset` changes the output tone frequency with no gap in the sample count.

- [ ] **Step 2: Run the tests and confirm they fail.**

  Run: `swift test --filter ModemChannelTests`. Expected: a compile error, because the types don't exist yet.

- [ ] **Step 3: Implement `FractionalResampler`.**

  - Polyphase windowed-sinc, Blackman-Harris window, with 256 phases.
  - Its cutoff is `0.45 × min(inRate, outRate)`.
  - It carries its fractional phase across calls.

- [ ] **Step 4: Implement `ModemChannel`.**

  1. Shift with the NCO by `−(dialOffset + 1800)`, so the box centre lands at DC.
  2. Run `DecimationPlan` stages down to a rate of at least 12 kHz.
  3. Apply a complex low-pass of ±1700 Hz to the channel.
  4. Take `NCO(+1800)` with `mixReal`, giving real audio 300…3300.
  5. Resample to exactly 12 000 Hz with the `FractionalResampler`.

  There is no AGC: levels must stay linear for SNR estimates.

- [ ] **Step 5: Run the tests and confirm they pass.**

  Run: `swift test --filter ModemChannelTests`. Expected: PASS.

- [ ] **Step 6: Commit.** Message: `feat(dsp): add fractional resampler and 12 kHz modem channel`.

---

### Task 2: ModemBox geometry

**Files:**
- Create: `Sources/SubFloorCore/ModemBox.swift`
- Test: `Tests/SubFloorCoreTests/ModemBoxTests.swift`

**Interfaces:**
- Produces: `public struct ModemBox: Codable, Equatable, Sendable`
  - Stored: `var dialHz: Double`, a display frequency.
  - Constants:
    - `static let audioLow = 300.0`
    - `static let audioHigh = 3300.0`
  - Computed edges: `var lowerHz: Double { dialHz + 300 }`, `var upperHz: Double { dialHz + 3300 }`, `var centerHz`.
  - Conversions: `func audioHz(forRF:) -> Double`, `func rfHz(forAudio:) -> Double`, `func contains(rf:) -> Bool`.
  - Placement: `static func centered(on rfCenter: Double) -> ModemBox`, which sets `dial = rfCenter − 1800`.
  - Validity: `func isInside(captureCenter: Double, captureSpan: Double) -> Bool`, true when the whole box lies within ±45% of the span from the centre.
  - Dragging: `mutating func move(byHz:)`.

- [ ] **Step 1: Write the failing tests.**

  `edgesAndMapping`
  - For `dial 14_070_000`: lower 14 070 300, upper 14 073 300.
  - `audioHz(forRF: 14_071_520) == 1520`.
  - The round trip `rfHz(forAudio:)` returns the original value.

  `centeredOnPlacesMiddle`
  - Expect: `centered(on: 14_072_000).centerHz == 14_072_000`.

  `insideCapture`
  - Expect: a box at the capture centre is inside. A box shifted by `0.46 × span` is not.

  `upconverterLeavesDisplayMathsUnchanged`
  - Setup: with `Upconverter(enabled: true)`, take `hardware(fromDisplay: box.lowerHz)`.
  - Expect: it equals `box.lowerHz + 125_000_000`. The box stays entirely in display Hz.

- [ ] **Step 2: Run the tests and confirm they fail.**

  Run: `swift test --filter ModemBoxTests`. Expected: FAIL.

- [ ] **Step 3: Implement `ModemBox`.**

- [ ] **Step 4: Run the tests and confirm they pass.**

- [ ] **Step 5: Commit.** Message: `feat(core): add modem box geometry`.

---

### Task 3: Modem framework types and test signal support

**Files:**
- Create: `Sources/Modems/Framework/ModemTypes.swift`
- Test: `Tests/ModemsTests/Support/ModemTestSignals.swift`, `Tests/ModemsTests/ModemTestSignalsTests.swift`

**Interfaces:**
- Produces:
  - **`ModeID`**
    - `public enum ModeID: String, CaseIterable, Codable, Sendable, Identifiable { case cw, psk31, rtty, ft8, wspr }`
    - `var label: String`: "CW", "PSK31", "RTTY", "FT8", "WSPR"
    - `var isSlotMode: Bool`
    - `var listenWidthHz: Double`: 250, 150, 400, 100, 50
    - `var lockRangeHz: Double`: 25, 15, 30, 10, 5
  - **`ModemSettings`**
    - `public struct ModemSettings: Sendable, Equatable`
    - Fields: `var mode: ModeID?`, where nil means Off; `var autoDetect = false`; `var audioWide = false`; `var slotModesEnabled = true`
  - **`SignalSnapshot`**
    - `public struct SignalSnapshot: Sendable, Equatable, Identifiable`
    - Fields: `id: Int`, `frequencyHz: Double`, `snrDb: Float`, `mode: ModeID?`, `submode: String`, `isQuiet: Bool`, `isCursor: Bool`
  - **`DecodedText`**
    - `public struct DecodedText: Sendable, Equatable`
    - Fields: `trackID: Int`, `text: String`
  - **`SlotDecode`**
    - `public struct SlotDecode: Sendable, Equatable, Identifiable`
    - Fields: `id: UUID`, `mode: ModeID`, `slotStart: Date`, `frequencyHz: Double`, `snrDb: Float`, `timeOffset: Double`, `message: String`
  - **`SignalDecoder`**
    - `public protocol SignalDecoder: AnyObject`
    - Members:
      - `var frequencyHz: Double { get }`
      - `var submode: String { get }`
      - `func process(_ audio: UnsafeBufferPointer<Float>) -> String`, which returns new text
      - `func constellation() -> [SIMD2<Float>]`
      - `func reset()`
  - **`StreamingModem`**
    - `public protocol StreamingModem`
    - Members:
      - `static var id: ModeID { get }`
      - `static func makeDecoder(frequencyHz: Double, sampleRate: Double) -> any SignalDecoder`
  - **`SlotModem`**
    - `public protocol SlotModem`
    - Members:
      - `static var id: ModeID { get }`
      - `static var slotSeconds: Double { get }`
      - `static func decode(samples: [Float], sampleRate: Double, slotStart: Date, audioBand: ClosedRange<Double>) -> [SlotDecode]`
  - **`ModemCatalog`**
    - `public enum ModemCatalog`
    - Members:
      - `static var streaming: [any StreamingModem.Type]`
      - `static var slot: [any SlotModem.Type]`
      - `static func streaming(_ id: ModeID) -> (any StreamingModem.Type)?`
      - `static func slot(_ id: ModeID) -> (any SlotModem.Type)?`
    - Both lists start empty. Tasks 5, 6, 7, 10 and 12 each append one line.
  - **Test-only, in `ModemTestSignals`:**
    - `static func awgn(_ x: [Float], snrDb: Double, sampleRate: Double = 12_000, seed: UInt64) -> [Float]`. Noise variance is set so that `10·log10(Psignal / (σ²·2500/(fs/2))) == snrDb`.
    - `static func characterAccuracy(sent: String, received: String) -> Double`, defined as `1 − levenshtein / sent.count`, clamped to ≥ 0.
    - `static func tone(_ hz: Double, seconds: Double, amplitude: Float = 0.5, sampleRate: Double = 12_000) -> [Float]`

- [ ] **Step 1: Write the tests.**

  `awgnHitsRequestedSNR`
  - Input: a 1 kHz tone at −10 dB.
  - Expect: the measured signal/noise ratio in 2.5 kHz is within 0.3 dB.

  `accuracyMetric`
  - "HELLO" vs "HELLO" → 1.0
  - "HELLO" vs "HELO" → 0.8
  - "HELLO" vs "" → 0

  `modeTable`
  - Expect: the `listenWidthHz` values are exactly as in the interface above.

- [ ] **Step 2: Run the tests and confirm they fail.**

  Run: `swift test --filter ModemTestSignalsTests`. Expected: FAIL.

- [ ] **Step 3: Implement the framework types and `ModemTestSignals`.**

  The phase-1 `Modem.swift` stays in place until Task 16, so names must not clash. `ModemCatalog` is the new registry.

- [ ] **Step 4: Run the tests and confirm they pass.** The full `swift test` must still pass.

- [ ] **Step 5: Commit.** Message: `feat(modems): add multi-signal modem framework types`.

---

### Task 4: SignalTracker

**Files:**
- Create: `Sources/Modems/Tracking/SignalTracker.swift`
- Test: `Tests/ModemsTests/SignalTrackerTests.swift`

**Interfaces:**
- **`SignalTracker`**
  - `public final class SignalTracker`
  - `init(sampleRate: Double = 12_000, band: ClosedRange<Double> = 300...3300)`
  - `func process(_ audio: UnsafeBufferPointer<Float>)`
  - `var tracks: [Track] { get }`
  - `var averagedSpectrumDb: [Float] { get }`
  - `var binHz: Double { get }`
  - `var samplesSeen: Int { get }`
  - `func reset()`
- **`Track`**
  - `public struct Track: Sendable, Equatable, Identifiable`
  - Fields:
    - `id: Int`
    - `frequencyHz: Double`
    - `snrDb: Float`
    - `bandwidthHz: Double`
    - `firstSeenSample: Int`
    - `lastActiveSample: Int`
    - `isQuiet: Bool`
    - `isFSKPair: Bool`
    - `peakOffsetsHz: [Double]`: secondary peaks relative to the centre, for the classifier
- **Constants:**
  - `static let quietAfterSeconds = 20.0`
  - `static let removeAfterSeconds = 120.0`

- [ ] **Step 1: Write the failing tests.** Every test uses 12 kHz audio from `ModemTestSignals`.

  `findsThreeCarriers`
  - Input: tones at 700, 1500 and 2400 Hz at +10 dB, run for 3 s.
  - Expect: exactly 3 tracks, each frequency within 1 Hz.

  `psk31SidebandsDoNotSpawnTracks`
  - Input: a BPSK31 idle signal at 1500 Hz. Task 6 provides the encoder; until then, use a two-tone approximation at 1484.4 and 1515.6 Hz.
  - Expect: exactly 1 track, at 1500 ± 3 Hz.

  `rttyPairIsOneTrack`
  - Input: tones at 1415 and 1585 Hz, alternating every 22 ms.
  - Expect: 1 track with `isFSKPair == true`, at 1500 ± 3 Hz.

  `weakNextToStrong`
  - Input: a +25 dB tone at 1000 Hz, plus a −5 dB tone at 1060 Hz.
  - Expect: both are tracked.

  `driftKeepsID`
  - Input: a tone sweeping 1 Hz/s from 1200 to 1230 Hz over 30 s.
  - Expect: the same track id is present at the end, at 1230 ± 2 Hz.

  `quietThenRemoved`
  - Input: a tone for 2 s, then silence (noise only).
  - Expect: after 21 s of silence `isQuiet == true`, and after 121 s the track is gone.

  `noiseOnlyMakesNoTracks`
  - Input: 30 s of AWGN.
  - Expect: 0 tracks.

- [ ] **Step 2: Run the tests and confirm they fail.**

  Run: `swift test --filter SignalTrackerTests`. Expected: FAIL.

- [ ] **Step 3: Implement the tracker.**

  - **Spectrum analysis:**
    - 4096-point FFT with a Hann window and 50% hop.
    - Power averaging with α = 0.3.
  - **Noise floor:** the median of the band's bins, smoothed with a 64-bin running median.
  - **Peak picking:**
    - A peak needs at least 6 dB over the floor, and must be a local max within ±5 bins.
    - Parabolic interpolation refines the frequency.
  - **Grouping:**
    - Merge peaks lying within ±20 Hz of a stronger peak into that peak's track, as sidebands. Record their offsets in `peakOffsetsHz`.
    - Pair peaks 170 ± 15 Hz apart and within 6 dB of each other as an FSK pair, centred between them.
  - **Track association:** nearest within ±10 Hz per frame, with its frequency updated by EMA α = 0.3.
  - **SNR:** `10·log10(peakPower / (floorPerBin × 2500/binHz))`.

- [ ] **Step 4: Run the tests and confirm they pass.**

- [ ] **Step 5: Commit.** Message: `feat(modems): add signal tracker`.

---

### Task 5: Multi-signal CW decoder

**Files:**
- Create: `Sources/Modems/CW/CWModem.swift`
- Modify: `Sources/Modems/CW/CWDecoderCore.swift`. Add `public func process(envelope magnitudes: UnsafeBufferPointer<Float>, blockMs: Double) -> String`. This lets a caller feed per-block magnitudes. The existing `process(_:)` keeps working through the same internal `step`.
- Modify: `Sources/Modems/Framework/ModemTypes.swift`. Register `CWModem` in `ModemCatalog.streaming`.
- Test: `Tests/ModemsTests/CWModemTests.swift`

**Interfaces:**
- `public enum CWModem: StreamingModem`, with `id = .cw`.
- Its decoder is `CWSignalDecoder: SignalDecoder`, with `submode` returning "CW nnWPM".

- [ ] **Step 1: Write the failing tests.**

  `decodesAtMinus8dB`
  - Input: "CQ TEST DE W1AW K" at 20 WPM, 800 Hz, −8 dB, seed 1.
  - Expect: character accuracy ≥ 0.95.

  `twoSignals150HzApartDecodeIndependently`
  - Input: "PARIS PARIS" at 700 Hz and "TEST TEST" at 850 Hz, both at +10 dB, 18 and 25 WPM.
  - Expect: each decoder (built at its own frequency) has accuracy ≥ 0.95 on its own text, and its text contains none of the other's words.

  `noiseOnlyNoText`
  - Input: 60 s of noise.
  - Expect: decoded non-space characters == 0.

- [ ] **Step 2: Run the tests and confirm they fail.**

  Run: `swift test --filter CWModemTests`. Expected: FAIL.

- [ ] **Step 3: Implement the CW decoder.**

  Signal chain:
  1. NCO-mix to baseband at the track frequency.
  2. A complex FIR decimator: 12 k → 1 k, with a low-pass cutoff of 60 Hz.
  3. Take |z| averaged per 5 ms block.
  4. Feed the result to `CWDecoderCore.process(envelope:blockMs:)`.

  AFC: every 1 s, re-estimate the frequency from the phase slope of the baseband during key-down, and move the NCO, at most 2 Hz per update.

- [ ] **Step 4: Run the tests and confirm they pass.** Also confirm the phase-1 `CWDecoderTests` still pass.

- [ ] **Step 5: Commit.** Message: `feat(modems): add multi-signal CW decoder`.

---

### Task 6: PSK31 (BPSK31 and QPSK31)

**Files:**
- Create:
  - `Sources/Modems/PSK31/Varicode.swift`
  - `Sources/Modems/PSK31/PSK31Encoder.swift`
  - `Sources/Modems/PSK31/QPSKViterbi.swift`
  - `Sources/Modems/PSK31/PSK31Decoder.swift`
- Modify: `ModemTypes.swift`, to register `PSK31Modem`.
- Test: `Tests/ModemsTests/PSK31Tests.swift`

**Interfaces:**
- `public enum Varicode`:
  - `static func encode(_ c: Character) -> [Bool]`
  - `static func decode(_ bits: [Bool]) -> Character?`
  - Uses the standard G3PLX PSK31 Varicode, all 128 ASCII codes. Verify it against the published table.
- `public struct PSK31Encoder`:
  - `static func audio(text: String, frequencyHz: Double, qpsk: Bool = false, sampleRate: Double = 12_000, leadInSeconds: Double = 1, amplitude: Float = 0.5) -> [Float]`
  - Produces a raised-cosine-shaped 31.25 Bd signal, with an idle preamble of phase reversals and a postamble of carrier.
- `public enum PSK31Modem: StreamingModem`, with `id = .psk31`. Its decoder `submode` returns "BPSK31" or "QPSK31".
- `QPSKViterbi`:
  - Constraint length K = 5, generator polynomials 0x19 and 0x17. This is the G3PLX QPSK31 code; verify it against the published description.
  - Uses a 5 × 4 decode delay, as fldigi does.

- [ ] **Step 1: Write the failing tests.**

  Test text: `let text = "the quick brown fox JUMPS over the lazy dog 0123456789 CQ CQ DE W1AW PSE K"`.

  `varicodeRoundTrip`
  - Expect: every ASCII 0…127 round-trips through encode/decode.
  - Expect: the code for "e" is `[true, true]` (11) and for space is `[true]` (1).

  `bpskCleanDecode`
  - Input: +10 dB at 1500 Hz.
  - Expect: accuracy == 1.0 after the lead-in.

  `bpskMinus10dB`
  - Input: −10 dB, seeds 1…5.
  - Expect: mean accuracy ≥ 0.95.

  `qpskCleanDecode`
  - Input: QPSK at +10 dB.
  - Expect: accuracy == 1.0 with `submode == "QPSK31"`. The decoder is not told the mode; it must detect it.

  `afcTracksDrift`
  - Input: BPSK at +5 dB with the carrier drifting 0.5 Hz/s for 40 s.
  - Expect: accuracy ≥ 0.95.

  `noiseSquelch`
  - Input: 60 s of noise.
  - Expect: 0 non-space characters.

  `constellationClusters`
  - Expect: after a clean BPSK decode, `constellation()` returns ≥ 64 points.
  - Expect: those points split into 2 clusters, with each point within 0.35 of its cluster centre (normalised magnitude).

- [ ] **Step 2: Run the tests and confirm they fail.**

  Run: `swift test --filter PSK31Tests`. Expected: FAIL.

- [ ] **Step 3: Implement Varicode and the encoder.**

- [ ] **Step 4: Implement the decoder.**

  Signal chain:
  1. NCO-mix to baseband.
  2. Decimate 12 k → 500 Hz (16 samples per symbol).
  3. Matched filter: a raised cosine one symbol wide.
  4. Gardner timing-error detector, with loop gain chosen to settle within 32 symbols.
  5. Costas-loop phase tracking for BPSK, or a 4th-power loop for QPSK.
  6. Feed the Costas frequency error to the NCO, as AFC.
  7. Differential decode:
     - **BPSK:** a phase change of π is bit 0, and no change is bit 1.
     - **QPSK:** feed the differential phase dibits into the Viterbi decoder.
  8. Varicode: a character ends at "00".

  Squelch:
  - Metric: an EMA over symbols of how tightly each symbol sits near its constellation point.
  - Emit text only above the threshold, and require 8 consecutive good symbols to open.

  BPSK vs QPSK detection: compare cluster variance under 2-point and 4-point hypotheses over the last 64 symbols.

- [ ] **Step 5: Run the tests and confirm they pass.**

- [ ] **Step 6: Commit.** Message: `feat(modems): add PSK31 BPSK/QPSK encoder and decoder`.

---

### Task 7: RTTY

**Files:**
- Create: `Sources/Modems/RTTY/Baudot.swift`, `RTTYEncoder.swift`, `RTTYDecoder.swift`
- Modify: register `RTTYModem`.
- Test: `Tests/ModemsTests/RTTYTests.swift`

**Interfaces:**
- `public enum Baudot`:
  - `static func encode(_ text: String) -> [UInt8]`, 5-bit codes with LTRS/FIGS shifts inserted
  - `struct Decoder { mutating func decode(_ code: UInt8) -> Character? }`, which handles LTRS/FIGS and unshift-on-space
- `public struct RTTYEncoder`:
  - `static func audio(text: String, centerHz: Double, baud: Double = 45.45, shiftHz: Double = 170, reverse: Bool = false, sampleRate: Double = 12_000, amplitude: Float = 0.5) -> [Float]`
  - The mark tone is the upper frequency in normal (non-reversed) polarity.
  - Each character is 1 start bit, 5 data bits (LSB first) and 1.5 stop bits.
- `public enum RTTYModem: StreamingModem`, with `id = .rtty` and decoder `submode` "RTTY 45".

- [ ] **Step 1: Write the failing tests.**

  Test text: `"RYRYRY CQ TEST DE OH2XX OH2XX 599 001 K"`.

  `baudotRoundTrip`
  - Expect: the text round-trips, including the FIGS for the digits.

  `cleanDecode`
  - Input: +10 dB.
  - Expect: accuracy == 1.0.

  `minus5dB`
  - Input: −5 dB, seeds 1…5.
  - Expect: mean accuracy ≥ 0.95.

  `reverseShiftAutoDetected`
  - Input: a reversed signal at +10 dB.
  - Expect: accuracy == 1.0 within 3 s.

  `noiseOnly`
  - Input: 60 s of noise.
  - Expect: 0 non-space characters.

- [ ] **Step 2: Run the tests and confirm they fail.**

  Run: `swift test --filter RTTYTests`. Expected: FAIL.

- [ ] **Step 3: Implement the decoder.**

  - **Filters:**
    1. Mix the centre down to baseband.
    2. Run mark/space matched filters at ±85 Hz, using complex FIRs one bit long.
  - **Detection:** compare the envelopes, with ATC tracking each envelope's peak and floor separately.
  - **Framing:**
    - Detect the start bit by looking for a mark→space edge.
    - Sample at bit centres.
    - Validate the stop bit, and reject the frame if it is mark for less than half a bit.
  - **Polarity:** if more than 30% of frames fail in normal polarity over 2 s while reverse polarity frames cleanly, flip.
  - **Squelch:** emit nothing while the mark/space contrast is below threshold.

- [ ] **Step 4: Run the tests and confirm they pass.**

- [ ] **Step 5: Commit.** Message: `feat(modems): add RTTY encoder and decoder`.

---

### Task 8: Signal classifier

**Files:**
- Create: `Sources/Modems/Tracking/SignalClassifier.swift`
- Test: `Tests/ModemsTests/SignalClassifierTests.swift`

**Interfaces:**
- **Consumes:**
  - `Track` (Task 4)
  - The CW, PSK31 and RTTY encoders (Tasks 5–7)
  - The FT8 encoder from Task 10, used for test signals only. Until Task 10 lands, the FT8 test is written as a pending `withKnownIssue`. Task 10 enables it.
- **Produces:**
  - `public struct Classification: Sendable, Equatable`
    - Fields: `mode: ModeID?`, `submode: String`, `confidence: Float`
  - `public enum SignalClassifier`
    - `static func classify(track: Track, audio: ArraySlice<Float>, sampleRate: Double, utcSecondOfMinute: Double?) -> Classification`
    - `audio` is the last ≥ 2 s of box audio.

- [ ] **Step 1: Write the failing tests.**

  Trial setup: random frequencies from 600 to 2800 Hz, at +5 dB, 20 trials per mode, seeded.

  `classifiesEachMode`
  - Expect: each of CW, BPSK31, QPSK31 and RTTY is classified correctly in ≥ 90% of trials.

  `classifiesFT8`
  - Input: an FT8 signal at +5 dB, aligned to a slot. Enabled in Task 10.
  - Expect: ≥ 90% correct.

  `unknownForPlainCarrier`
  - Input: a steady unmodulated carrier.
  - Expect: `mode == nil`.

- [ ] **Step 2: Run the tests and confirm they fail.**

  Run: `swift test --filter SignalClassifierTests`. Expected: FAIL.

- [ ] **Step 3: Implement rule-based classification.** Check each rule in order:

  1. **FSK pair:** the track is an FSK pair with 170 Hz spacing → RTTY.
  2. **On/off envelope:** the baseband envelope's standard deviation over mean is > 0.6, and its histogram is bimodal (on/off) → CW.
  3. **PSK:** the occupied bandwidth is ≤ 80 Hz and peaks sit at ±15.6 ± 2 Hz (or a 31.25 Hz symbol-rate line appears in the squared signal's spectrum) → PSK31. A trial-demodulated constellation decides BPSK vs QPSK.
  4. **FT8:** about 8 tone lines at 6.25 Hz spacing appear within 50 Hz, with energy onset aligned to :00/:15/:30/:45 ± 2 s → FT8.
  5. **WSPR:** the occupied bandwidth is about 6 Hz and the audio lies in 1400–1600 Hz → WSPR.
  6. **Otherwise:** `nil`.

  Confidence comes from how close each feature is to its threshold.

- [ ] **Step 4: Run the tests and confirm they pass.**

- [ ] **Step 5: Commit.** Message: `feat(modems): add auto-detect signal classifier`.

---

### Task 9: ModemEngine and CursorAnalyzer

**Files:**
- Create: `Sources/Modems/Engine/ModemEngine.swift`, `Sources/Modems/Engine/CursorAnalyzer.swift`
- Test: `Tests/ModemsTests/ModemEngineTests.swift`

**Interfaces:**
- Consumes:
  - `SignalTracker`, `SignalClassifier`, `ModemCatalog`, `ModemSettings`
  - `SlotRecorder` (Task 10). Until Task 10 lands, the engine has an optional `slotSink` closure, which is nil in this task.
- Produces:
  - **`CursorFrame`**
    - `public struct CursorFrame: Sendable`
    - Fields:
      - `waveform: [Float]`: up to 480 samples, trigger-aligned on a rising zero crossing
      - `spectrumDb: [Float]`: 401 bins covering ±100 Hz
      - `spectrumCenterHz: Double`
      - `iq: [SIMD2<Float>]`: up to 128 points
      - `frequencyHz: Double`
      - `snrDb: Float`
      - `submode: String`
      - `symbolRate: Double?`
  - **`ModemOutput`**
    - `public struct ModemOutput: Sendable`
    - Fields:
      - `var text: [DecodedText]`
      - `var signals: [SignalSnapshot]?`: non-nil at most every 0.5 s
      - `var listenAudio: [Float]`: 12 kHz
      - `var cursor: CursorFrame?`: non-nil at most every 1/30 s
  - **`ModemEngine`**
    - `public final class ModemEngine`
    - `init(sampleRate: Double = 12_000, maxDecoders: Int = 40)`
    - `var settings: ModemSettings`
    - `func lockCursor(atAudioHz: Double)`: snaps to the nearest track within the mode's lock range. If no track is close enough, it locks at that exact frequency.
    - `func unlockCursor()`
    - `var cursorTrackID: Int? { get }`
    - `func nudgeCursor(_ direction: Int)`: moves the cursor to the next or previous track by frequency
    - `func resetForBoxMove()`: clears tracks, decoders and the cursor
    - `func process(_ audio: UnsafeBufferPointer<Float>, sampleIndex: Int) -> ModemOutput`

- [ ] **Step 1: Write the failing tests.**

  `parallelDecode`
  - Input: five PSK31 signals at 600, 900, 1300, 1900 and 2600 Hz (+5 dB each, different texts), plus two CW signals at 2200 and 3000 Hz (+10 dB), in one audio stream for 40 s. Settings: `mode .psk31`, `autoDetect true`.
  - Expect: every signal's accumulated text by `trackID` has accuracy ≥ 0.95 against its sent text, and each has a matching `SignalSnapshot` within ±3 Hz with the correct `mode`.

  `manualModeDecodesAllWithOneModem`
  - Settings: `autoDetect false`, `mode .cw`.
  - Input: three CW signals.
  - Expect: all three are decoded.

  `noGarbage`
  - Input: 60 s of noise, with each mode in turn and with auto-detect.
  - Expect: total non-space characters == 0.

  `cursorAlwaysDecodedBeyondCap`
  - Setup: `maxDecoders: 2`, with four PSK signals.
  - Expect: after locking the cursor on the weakest one, its text is decoded.

  `unclassifiedCursorUsesFallbackMode`
  - Settings: `autoDetect true`, `mode .rtty`.
  - Input: an RTTY signal at −3 dB, below the classifier's threshold.
  - Expect: locking the cursor on it decodes the RTTY text.

  `listenAudioNarrowVsWide`
  - Input: a cursor on 1500 Hz with a 2500 Hz interferer.
  - Expect: narrow listen audio has the 2500 Hz component ≥ 30 dB down; wide has it within 3 dB.
  - Expect: with no cursor, the listen audio is wide.

  `boxMoveClears`
  - Expect: after decoding, `resetForBoxMove()` leaves the next output's `signals` empty, and no `DecodedText` appears for old track ids.

  `cursorFrameContents`
  - Input: a BPSK cursor.
  - Expect: `iq.count ≥ 64`, `spectrumDb.count == 401`, a peak within ±1 bin of the centre, `waveform.count == 480`, and `waveform[0]` near 0 with a rising slope.

- [ ] **Step 2: Run the tests and confirm they fail.**

  Run: `swift test --filter ModemEngineTests`. Expected: FAIL.

- [ ] **Step 3: Implement the engine.**

  - **Tracker:** runs on every block.
  - **Decoder assignment:**
    - With auto-detect on: classify each new track after 2 s of observation, and re-classify every 10 s.
    - With auto-detect off: every track gets the selected streaming mode.
    - When `settings.mode` is a slot mode, no streaming decoders run.
  - **Priority:**
    - Decoders are allocated to the cursor first, then by SNR, up to `maxDecoders`.
    - The cursor gets a decoder even with no track: it decodes at its locked frequency, in its detected mode or the fallback `settings.mode`.
  - **Listen audio:**
    - It is a bandpass of `listenWidthHz` centred on the cursor (complex FIR shift-filter-shift, back to real).
    - When unlocked, or with `audioWide`, it is the raw box audio.
  - **CursorAnalyzer:**
    - A 24 000-point FFT over the last 2 s, giving 0.5 Hz bins, with a ±100 Hz slice resampled to 401 bins.
    - The decoder's `constellation()` supplies the IQ points.
    - Waveform: the last 480 samples of the narrow-filtered audio, aligned to a rising zero crossing.

- [ ] **Step 4: Run the tests and confirm they pass.**

- [ ] **Step 5: Commit.** Message: `feat(modems): add modem engine with cursor priority and bench`.

---

### Task 10: ft8_lib vendoring, FT8Modem and SlotRecorder

**Files:**
- Create:
  - `Sources/CFT8/` holds ft8_lib's `ft8/` and `common/` C sources and headers, needed for decode and encode. It also holds `LICENSE`, `VENDORED.md` (the upstream URL `https://github.com/kgoba/ft8_lib` and the pinned commit SHA) and `include/cft8.h`, an umbrella header.
  - `Sources/Modems/FT8/FT8Modem.swift`, `FT8Encoder.swift`
  - `Sources/Modems/Engine/SlotRecorder.swift`
- Modify:
  - `Package.swift`: add `.target(name: "CFT8", path: "Sources/CFT8", cSettings: [.unsafeFlags(["-O2"])])`, and make `Modems` depend on `CFT8`.
  - Register `FT8Modem`. Wire `SlotRecorder` into `ModemEngine`.
  - Enable the FT8 classifier test from Task 8.
- Test: `Tests/ModemsTests/FT8Tests.swift`, `Tests/ModemsTests/SlotRecorderTests.swift`

**Interfaces:**
- `public enum FT8Encoder`
  - `static func audio(message: String, audioHz: Double, sampleRate: Double = 12_000, amplitude: Float = 0.5) -> [Float]?`
  - Packs the message with ft8_lib's `pack77` and encodes it to 79 tones.
  - Synthesizes GFSK in Swift: BT = 2.0, 0.16 s symbols, 6.25 Hz tone spacing.
  - Output is 15 s long with the signal starting at 0.5 s.
- `public enum FT8Modem: SlotModem`
  - `id = .ft8`, `slotSeconds = 15`
  - `decode` runs ft8_lib's monitor and decode path with up to 3 subtraction passes. If the vendored version lacks subtraction, a single pass is accepted; record which.
- `public final class SlotRecorder`
  - `init(sampleRate: Double = 12_000, retainSeconds: Double = 150)`
  - `func append(_ audio: UnsafeBufferPointer<Float>, firstSampleTime: Date)`
  - `func dueSlots(modes: [any SlotModem.Type], now: Date) -> [SlotJob]`
  - `public struct SlotJob { mode: any SlotModem.Type; samples: [Float]; slotStart: Date }`
  - A slot is due once `now ≥ slotStart + slotSeconds + 0.5`.
  - A slot is skipped if any sample in its window is missing: a timestamp discontinuity of more than 20 ms counts as a gap.
- `ModemEngine` gains:
  - `func appendSlotAudio(_ audio: UnsafeBufferPointer<Float>, firstSampleTime: Date)`, called from `process`, using the time the app passes in
  - `func dueSlotJobs(now: Date) -> [SlotJob]`
  - `SlotJob`s are only produced when `settings.slotModesEnabled` is true and either the mode is a slot mode or auto-detect is on.

- [ ] **Step 1: Vendor ft8_lib.**

  - Shallow-clone `https://github.com/kgoba/ft8_lib` into the scratchpad.
  - Copy only `ft8/*.c`, `ft8/*.h`, `common/*.c` and `common/*.h` (excluding audio-file and wave I/O, which aren't needed), plus `LICENSE`.
  - Record the commit SHA in `VENDORED.md`.

  Run: `swift build`. Expected: CFT8 compiles with no warnings that come from our flags.

- [ ] **Step 2: Write the failing tests.**

  `roundTripClean`
  - Input: `"CQ W1AW FN31"` at 1200 Hz.
  - Expect: decodes to exactly that message, at 1200 ± 3 Hz.

  `sixSignalsOneSlot`
  - Input: six different messages at different audio frequencies (from 500 to 2800 Hz), all at −10 dB.
  - Expect: all six are decoded.

  `minus20dB`
  - Input: 20 trials at −20 dB, seeded.
  - Expect: ≥ 16 decoded. If not, record the achieved threshold (the lowest SNR with ≥ 80%) in the report and FLAG it. Do not change the assertion.

  `bandFilter`
  - Expect: decodes outside `audioBand` are omitted.

  `slotBoundaries`
  - Expect: the slot start for 12:00:16 UTC is 12:00:15. For WSPR, the slot start for 12:01:30 is 12:00:00.

  `gapSkipsSlot`
  - Input: append audio for a slot with a 100 ms timestamp jump inside it.
  - Expect: no job is produced for that slot.

  `jobContainsExactSlotSamples`
  - Expect: `samples.count == 15 × 12 000`, with samples starting at the slot boundary.

- [ ] **Step 3: Run the tests and confirm they fail.**

  Run: `swift test --filter "FT8Tests|SlotRecorderTests"`. Expected: FAIL.

- [ ] **Step 4: Implement `FT8Encoder`, `FT8Modem` and `SlotRecorder`, and wire `SlotRecorder` into the engine.**

- [ ] **Step 5: Run the tests and confirm they pass,** including the now-enabled FT8 classifier test.

- [ ] **Step 6: Commit.** Message: `feat(modems): vendor ft8_lib, add FT8 slot decoding and UTC slot recorder`.

---

### Task 11: WSPR codec (encoder side, written from the protocol description)

**Files:**
- Create: `Sources/Modems/WSPR/WSPRCodec.swift`, `Sources/Modems/WSPR/WSPRFano.swift`, `Sources/Modems/WSPR/WSPREncoder.swift`
- Test: `Tests/ModemsTests/WSPRCodecTests.swift`

**Reference:** G4JNT, "The WSPR Coding Process: Non-normative description" (public), and the WSPR mode description in the WSJT-X user guide (prose, not code).
- Implement from these. **Do not open or copy WSJT-X or wsprd source.**
- The subagent may fetch the G4JNT PDF or text from the web to verify constants. Record the URL used in a comment.

**Interfaces:**
- `public enum WSPRCodec`
  - `static func pack(call: String, grid: String, powerDbm: Int) -> [UInt8]?`
    - Packs into the 50-bit Type 1 message: 28-bit callsign and 22-bit locator+power, as 7 bytes with the last 6 bits zero, per G4JNT.
  - `static func unpack(_ bytes: [UInt8]) -> (call: String, grid: String, powerDbm: Int)?`
  - `static func convolve(_ bytes: [UInt8]) -> [UInt8]`
    - Produces 162 code bits. Constraint length 32, rate 1/2.
    - Polynomials `0xF2D05351` and `0xE4613C47`.
  - `static func interleave(_ bits: [UInt8]) -> [UInt8]`, the bit-reversal permutation of 8-bit addresses, keeping addresses < 162
  - `static func deinterleave(_ bits: [UInt8]) -> [UInt8]`
  - `static let syncVector: [UInt8]`, the 162-element pseudo-random sync vector from the reference. Verify every bit.
  - `static func channelSymbols(call:grid:powerDbm:) -> [UInt8]?`, computed per symbol as `sync[i] + 2 × data[i]` (values 0…3)
- `public enum WSPRFano`
  - `static func decode(softSymbols: [Float], maxCycles: Int = 10_000) -> [UInt8]?`
  - Fano sequential decoding of the K = 32 code. Its input is 162 soft bit metrics; it returns 7 bytes, or nil.
- `public enum WSPREncoder`
  - `static func audio(call:grid:powerDbm:audioHz: Double, sampleRate: Double = 12_000, amplitude: Float = 0.5) -> [Float]?`
  - 4-FSK with 1.4648 Hz tone spacing (12 000 / 8192). Each symbol is 8192 samples at 12 kHz.
  - 162 symbols, starting at t = 1 s within a 120 s buffer.

- [ ] **Step 1: Write the failing tests.**

  `packUnpackRoundTrip`
  - Inputs: `("K1ABC","FN42",37)`, `("G4JNT","IO90",30)` and `("W1AW","FN31",23)`.

  `knownChannelSymbols`
  - Input: `("K1ABC","FN42",37)`.
  - Expect: the 162 channel symbols equal the published example vector in the G4JNT document. Paste that vector into the test from the reference.

  `fanoDecodesClean`
  - Expect: hard-decision soft metrics (±1) from `convolve` decode back to the original bytes.

  `fanoCorrectsErrors`
  - Input: 10 random bit flips out of 162.
  - Expect: it still decodes.

  `interleaveInverse`
  - Expect: `deinterleave(interleave(x)) == x`.

- [ ] **Step 2: Run the tests and confirm they fail.**

  Run: `swift test --filter WSPRCodecTests`. Expected: FAIL.

- [ ] **Step 3: Implement the codec, Fano and encoder.**

  Fano decoding:
  - Use the standard Fano algorithm with threshold step Δ = 60 on integer-scaled metrics.
  - Build the metric table from the log-likelihood of a soft symbol given 0 or 1, at a nominal Eb/N0.

- [ ] **Step 4: Run the tests and confirm they pass.**

- [ ] **Step 5: Commit.** Message: `feat(modems): add WSPR codec, Fano decoder and encoder`.

---

### Task 12: WSPR demodulator and SlotModem

**Files:**
- Create: `Sources/Modems/WSPR/WSPRDecoder.swift`
- Modify: register `WSPRModem` in `ModemCatalog.slot`.
- Test: `Tests/ModemsTests/WSPRDecoderTests.swift`

**Interfaces:**
- `public enum WSPRModem: SlotModem`
  - `id = .wspr`, `slotSeconds = 120`
  - `decode` returns messages formatted as `"K1ABC FN42 37"`.

- [ ] **Step 1: Write the failing tests.**

  `cleanDecode`
  - Input: one signal at 1500 Hz, +0 dB.
  - Expect: the message decodes, at 1500 ± 2 Hz.

  `twoSignals`
  - Input: signals at 1450 and 1550 Hz, both at −15 dB.
  - Expect: both decode.

  `minus26dBGate`
  - Input: 20 seeded trials at −26 dB.
  - Expect: ≥ 16 decoded.

  `minus28dBStretch`
  - Input: 20 trials at −28 dB.
  - Record the decode count in the test output with `print`. This is not asserted.

  `timeOffsetTolerance`
  - Input: the signal starting at 0 s and at 2 s instead of 1 s.
  - Expect: both still decode.

  `noiseOnly`
  - Input: 120 s of noise.
  - Expect: zero decodes.

- [ ] **Step 2: Run the tests and confirm they fail.**

  Run: `swift test --filter WSPRDecoderTests`. Expected: FAIL.

- [ ] **Step 3: Implement the demodulator.**

  1. **Downconvert:** mix the slot audio down by 1500 Hz and decimate 12 k → 375 Hz complex (32×). Each symbol is then 256 samples.
  2. **Candidate search:**
     - Average the spectrum over the slot: 512-point FFTs at a quarter-symbol hop.
     - Search ±150 Hz, intersected with `audioBand`, for peaks above −30 dB SNR.
  3. **Fine search** for each candidate:
     - Time offset: −1…+3 s in steps of 1/4 symbol.
     - Frequency: ±1 Hz in 0.1 Hz steps.
     - Drift: −2…+2 Hz in 0.5 Hz steps.
     - Maximise the correlation of the sync tones with `syncVector`.
  4. **Soft symbols:** for each symbol, compute the 4 tone powers and form the data bit metric `(p2+p3) − (p0+p1)`, normalised.
  5. **Decode:** deinterleave, then run `WSPRFano.decode`. On success, unpack.
  6. **Validate:** reject a decode unless the callsign has a plausible format and the power is in the valid set `{0,3,7,…,60}`.
  7. **SNR:** estimate it in 2.5 kHz, matching the WSJT convention.

- [ ] **Step 4: Run the tests and confirm they pass.**

  If `minus26dBGate` fails after the steps above, record the achieved threshold in the report and FLAG it. Don't change the assertion.

- [ ] **Step 5: Commit.** Message: `feat(modems): add WSPR slot decoder`.

---

### Task 13: DecodeLog (row store)

**Files:**
- Create: `Sources/Modems/Framework/DecodeLog.swift`
- Test: `Tests/ModemsTests/DecodeLogTests.swift`

**Interfaces:**
- `public struct DecodeRow: Identifiable, Sendable, Equatable`
  - `id: Int`: the trackID; slot rows use negative ids
  - `frequencyHz: Double`
  - `mode: ModeID?`
  - `submode: String`
  - `snrDb: Float`
  - `recentText: String`: the last 160 characters
  - `history: String`: the last 4000 characters
  - `isQuiet: Bool`
  - `isCursor: Bool`
  - `utcTime: Date?`: set for slot rows
- `public struct DecodeLog: Sendable`
  - `var liveRows: [DecodeRow] { get }`: cursor first, then the rest ascending by frequency
  - `var slotRows: [DecodeRow] { get }`: newest slot first, capped at 200
  - `var heldNewCount: Int { get }`
  - `var holdNew: Bool`: set while the pointer is over the list
  - `mutating func apply(signals: [SignalSnapshot]?, text: [DecodedText], slotDecodes: [SlotDecode], now: Date)`
  - `mutating func releaseHeld()`
  - `mutating func clear()`
  - `func row(forTrack:) -> DecodeRow?`

- [ ] **Step 1: Write the failing tests.**

  `ordersByFrequencyWithCursorPinned`
  - Expect: rows are ordered 600, 900, 1300, and when the cursor is on 900, that row is first.

  `noReorderOnFrequencyJitter`
  - Input: the 900 Hz track drifts to 1301 Hz (passing the 1300 row).
  - Expect: the order is unchanged until the track is re-inserted by quiet and removal.

  `textAppendsAndTrims`
  - Expect: `recentText` is limited to the last 160 characters and `history` to 4000.

  `heldNew`
  - Expect: with `holdNew = true`, a new track increases `heldNewCount` and does not appear in `liveRows` until `releaseHeld()` is called or `holdNew` is set false.

  `quietAndRemoval`
  - Expect: a snapshot with `isQuiet` marks the row quiet, and a track missing from snapshots removes its row.

  `slotRowsNewestFirstAndCapped`
  - Expect: 250 slot decodes leave 200 rows, newest first, each with `utcTime` set.

  `slotClaimedTrackFolded`
  - Expect: a live track within ±10 Hz of a slot decode from the last 30 s is hidden from `liveRows`.

  `cursorOnSlotSignalShowsLatestMessages`
  - Expect: when the cursor's frequency is within ±10 Hz of slot decodes, the cursor's live row `recentText` shows their messages.

- [ ] **Step 2: Run the tests and confirm they fail.**

  Run: `swift test --filter DecodeLogTests`. Expected: FAIL.

- [ ] **Step 3: Implement `DecodeLog`.**

  A row's sort key is frozen at insertion. That is what keeps rows from reordering while visible.

- [ ] **Step 4: Run the tests and confirm they pass.**

- [ ] **Step 5: Commit.** Message: `feat(modems): add decode log row store`.

---

### Task 14: Engine integration (modem thread, stores, audio routing, clock check)

**Files:**
- Create:
  - `Sources/SubFloor/Engine/ModemWorker.swift`
  - `Sources/SubFloor/Engine/ModemStores.swift`
  - `Sources/SubFloor/Engine/ClockCheck.swift`
- Modify: `Sources/SubFloor/Engine/DSPEngine.swift`
- Test: `Tests/SubFloorTests/ModemWorkerTests.swift`, `Tests/SubFloorTests/ClockCheckTests.swift`

**Interfaces:**
- Consumes:
  - `ModemChannel` (Task 1)
  - `ModemEngine`, `ModemSettings`, `ModemOutput`, `CursorFrame`, `SlotJob` (Tasks 9–10)
  - `AudioOutput.push` and `FractionalResampler`
- **`DSPEngine` gains:**
  - `func update(modemBoxDialOffset: Double?)`, where nil means no box, or the box is outside the span
  - `func update(modemSettings: ModemSettings)`
  - `func modemCommand(_ c: ModemCommand)`
  - `enum ModemCommand { case lock(audioHz: Double), unlock, nudge(Int), resetBox }`
  - `let modemEvents: ModemEventQueue`
  - `let cursorFrames: CursorFrameStore`
- **`ModemEventQueue`:** a Mutex-guarded batch. The worker appends `DecodedText`, `SignalSnapshot` and `SlotDecode`; `drain()` returns and clears it. The main thread drains it at 10 Hz.
- **`CursorFrameStore`:** the same pattern as `SpectrumFrameStore`, with `publish(_:)` and `read(after:) -> (UInt64, CursorFrame)?`.
- **`ModemWorker`:**
  - Owns its own `Thread`, which reads 12 kHz audio from an `SPSCRing<Float>` (capacity 1 << 18).
  - Calls `ModemEngine.process`.
  - Pushes listen audio, upsampled 12 k → 48 k, to `AudioOutput`.
  - Dispatches `SlotJob`s to a serial `DispatchQueue(label: "subfloor.slots", qos: .utility)`, whose results go to `modemEvents`.
- **`ClockCheck`:**
  - `static func offsetSeconds(server: String = "time.apple.com", timeout: Double = 2) async -> Double?`, an SNTP v4 query over UDP
  - `static func parseOffset(response: [UInt8], t1: Double, t4: Double) -> Double?`
- **Audio routing:**
  - While `modemSettings.mode != nil` and a box is present, the DSP thread runs `ModemChannel` and does **not** push Receiver audio. The `ModemWorker` is then the single producer.
  - The switch happens only in the DSP loop's pending-config handling.

- [ ] **Step 1: Write the failing tests.**

  `workerDecodesSyntheticPSK`
  - Setup: feed `ModemWorker` 12 kHz PSK31 audio directly, bypassing the DSP thread, through a test initializer `init(audioSink:)`.
  - Expect: within 20 s of audio, `modemEvents.drain()` holds the text.

  `singleAudioProducer`
  - Setup: a `DSPEngine` lifecycle with `SyntheticSource`, toggling modem settings on and off.
  - Expect: Receiver audio pushes stop while the modem is on, verified through a test counter hook on `AudioOutput.push` callers.
  - Expect: no crash, and stop() joins both threads.

  `boxOutsideSpanStopsChannel`
  - Expect: `update(modemBoxDialOffset: nil)` stops box audio, so the worker gets no new samples.

  `sntpParse`
  - Input: a hand-built 48-byte NTP response with known transmit and receive timestamps.
  - Expect: the offset is computed per RFC 4330.

  `slotJobsRunOffThread`
  - Expect: an FT8 job decodes on the slots queue, and its results appear in `modemEvents`.

- [ ] **Step 2: Run the tests and confirm they fail.**

  Run: `swift test --filter "ModemWorkerTests|ClockCheckTests"`. Expected: FAIL.

- [ ] **Step 3: Implement the integration.**

  - Rebuild the `ModemChannel` when `inputRate` changes.
  - Call `resetForBoxMove()` when the dial offset changes by more than 5 Hz due to a drag. Small drags are acceptable, but every reset clears rows; see Task 15.
  - Every `ModemEngine` call happens on the worker thread. `settings` and commands arrive through a Mutex pending-struct, exactly like `DSPEngine.Pending`.

- [ ] **Step 4: Run the tests and confirm they pass.** The full `swift test` must also pass.

- [ ] **Step 5: Commit.** Message: `feat(app): run modem engine on its own thread with box channel and audio routing`.

---

### Task 15: AppModel modem state and spectrum interaction

**Files:**
- Modify:
  - `Sources/SubFloor/App/AppModel.swift`
  - `Sources/SubFloor/Rendering/SpectrumMTKView.swift`
  - `Sources/SubFloor/UI/SpectrumArea.swift`
  - `Sources/SubFloor/App/KeyboardController.swift`
- Test: `Tests/SubFloorTests/AppModelModemTests.swift`, `Tests/SubFloorTests/KeyboardControllerTests.swift`

**Interfaces:**
- **`AppModel` state:**
  - `private(set) var modemBox: ModemBox`, persisted in the session
  - `private(set) var modemSettings: ModemSettings`, persisted in the session
  - `private(set) var modemCursorAudioHz: Double?`
  - `private(set) var decodeLog: DecodeLog`
  - `var modemBoxActive: Bool { get }`, false when the box is outside the capture span
  - `private(set) var clockOffset: Double?`
- **`AppModel` actions:**
  - `func setModemMode(_ m: ModeID?)`
  - `func setAutoDetect(_ on: Bool)`
  - `func setAudioWide(_ on: Bool)`
  - `func moveModemBox(byHz:)`
  - `func recenterModemBox()`
  - `func lockModemCursor(atRF:)`
  - `func unlockModemCursor()`
  - `func nudgeModemCursor(_:)`
  - `func selectRow(_ id: Int)`
  - `func setRowHold(_ on: Bool)`
  - `func releaseHeldRows()`
- **Main-thread pump:** the 10 Hz drain of `modemEvents` into `decodeLog` lives in the existing stats timer.
- **`SpectrumInteraction` gains:**
  - `boxGrabRect: @MainActor () -> (lower: Double, upper: Double)?`: fractions of the grab tab's horizontal extent
  - `boxRange: @MainActor () -> (lower: Double, upper: Double)?`: the box body in fractions
  - `dragBox: @MainActor (_ deltaFraction: Double) -> Void`
  - `clickInBox: @MainActor (_ fraction: Double) -> Void`
- **Keyboard:**
  - `KeyboardController.decide` gains `modemActive: Bool`.
  - Esc → `.unlockModemCursor`.
  - When `modemActive`, ←/→ → `.nudgeModemCursor(±1)` instead of the VFO step.

- [ ] **Step 1: Write the failing tests** (on a hermetic model, never started).

  `recenterPlacesBoxAtViewCenter`
  - Expect: `modemBox.centerHz == viewport.centerHz`.

  `boxStaysPutOnVFOClick`
  - Expect: `click(atFraction:)` outside the box changes `vfoHz` but not `modemBox`.

  `lockCursorConvertsToAudio`
  - Expect: locking at RF `dial + 1520` gives `modemCursorAudioHz == 1520`.

  `boxOutsideSpanInactive`
  - Expect: tuning the VFO 1 MHz away, which retunes the centre, makes `modemBoxActive == false`; recentering makes it true.

  `slotModesDisabledForFileSource`
  - Expect: with `sourceKind == .file`, `modemSettings.slotModesEnabled == false`.

  `modeOffRestoresVFOAudio`
  - Expect: `setModemMode(nil)` sends a nil modem mode to the engine. Verify through a test hook that records engine updates.

  `escUnlocks` and `arrowsNudgeWhenModemActive`
  - These are keyboard `decide` tests.

  `sessionPersistsBoxAndSettings`
  - Expect: the box dial and settings round-trip through `UserDefaults`.

- [ ] **Step 2: Run the tests and confirm they fail.**

  Run: `swift test --filter "AppModelModemTests|KeyboardControllerTests"`. Expected: FAIL.

- [ ] **Step 3: Implement the state, actions, interaction hit-testing, overlay drawing and keyboard handling.**

  - **Hit-test order in `mouseDown`:**
    1. Grab tab → box drag.
    2. Passband edge → bandwidth drag.
    3. Inside the box body → cursor lock on mouseUp without drag. A drag that starts inside the box pans the spectrum, never the box.
    4. Elsewhere → the existing pending, click or pan behaviour.
  - **Overlay drawing, in the `SpectrumOverlay` Canvas:**
    - Box: a green 1.5 pt outline at 8% fill, a grab tab labelled "≡ MODE · 3 kHz" (or "AUTO · 3 kHz" with auto-detect on), and edge labels "300" and "3300 Hz".
    - Cursor: amber, labelled with its audio frequency, e.g. "1,520 Hz".
    - Tracked signals: thin blue ticks in the ruler at each track's frequency.
    - Inactive box: drawn dashed and grey.
  - **Cursor resize:** show the open-hand cursor over the grab tab.

- [ ] **Step 4: Run the tests and confirm they pass.**

- [ ] **Step 5: Commit.** Message: `feat(app): modem box, cursor and keyboard control on the spectrum`.

---

### Task 16: Modem panel UI and removal of the phase-1 modem framework

**Files:**
- Create:
  - `Sources/SubFloor/UI/Modem/ModemPanelView.swift`
  - `ModemControlStrip.swift`
  - `CursorBenchView.swift`
  - `SignalRowsView.swift`
- Delete:
  - `Sources/SubFloor/UI/ModemPanelView.swift` (old)
  - `Sources/Modems/Modem.swift`
  - `Sources/Modems/CW/CWDecoderModem.swift`
  - The old `AppModel.activeModem`/`activateModem` and `DSPEngine.modems` (`ModemHost`)
- Modify: `README.md` ("Adding a modem" for `StreamingModem`/`SlotModem` plus the `ModemCatalog` line, and the modem panel usage), and `Tests/ModemsTests/CWDecoderTests.swift` (keep the core tests; drop the registry/host tests that targeted removed types).
- Test: `Tests/SubFloorTests/ModemPanelTests.swift` covers view-model formatting only.

**Interfaces:**
- **`ModemPanelView`**
  - Laid out top to bottom: the control strip, the bench (collapsible), then `SignalRowsView`.
  - It follows the approved mockup in `.superpowers/brainstorm/82458-1792473151/content/modem-workspace.html`. Read that file.
- **`ModemControlStrip`**
  - Mode segmented control: Off, CW, PSK31, RTTY, FT8, WSPR.
  - The Auto-detect toggle (green when on), the "⌖ Re-center box" button, and the Audio Narrow/Wide picker.
  - Status: the signal count and the box dial frequency (`FrequencyFormatter.grouped`, "USB").
  - Slot progress, shown when FT8 or WSPR is active: a thin bar plus the seconds remaining.
  - Messages:
    - "FT8/WSPR need a live radio", for file sources
    - the box-outside-span message, with a Re-center button
    - the clock warning when `|clockOffset| > 1 s`
- **`CursorBenchView`**
  - Three Canvas panes: WAVEFORM, MICRO SPECTRUM ±100 Hz, and IQ.
  - They read `engine.cursorFrames` through a `TimelineView(.animation(minimumInterval: 1/30))`.
  - Each pane shows its readout in amber.
  - When no cursor is locked, the bench shows "Click a signal inside the box to analyse it".
- **`SignalRowsView`** shows two sections, "Live" and "Slot decodes", each with a header and collapsible.
  - **Cursor row** (amber):
    - 3 pt amber left bar and amber gradient background
    - 18 pt monospaced text that wraps
  - **Other rows:**
    - frequency in 13 pt `Theme.accent`, formatted with a thousands separator, e.g. "1,520 Hz"
    - mode in 11 pt secondary
    - text in 16 pt monospaced on a single line, truncating the head
    - SNR on the right
    - 0.45 opacity when quiet
  - **Behaviour:**
    - Clicking a row calls `model.selectRow`. Clicking the cursor row again unlocks it.
    - A disclosure on each row reveals its full `history` in a scrollable text block.
    - `.onHover` on the list calls `model.setRowHold`. A floating "N new ↓" pill calls `releaseHeldRows()`.
    - Slot rows show "HHMMSS  SNR  freq  message".

- [ ] **Step 1: Write the failing tests.**

  `frequencyFormatting`
  - Expect: 1520 → "1,520 Hz", and 720 → "720 Hz".

  `slotRowFormatting`
  - Expect: the time renders as "143215" in UTC regardless of the local time zone.

- [ ] **Step 2: Run the tests and confirm they fail.**

  Run: `swift test --filter ModemPanelTests`. Expected: FAIL.

- [ ] **Step 3: Implement the views.**

  Delete the old framework and fix every reference to it. `ContentView` uses the new `ModemPanelView`.

- [ ] **Step 4: Verify.**

  - The full `swift test` passes.
  - `swift build -c release` succeeds.
  - Grepping for `ModemHost|activateModem|CWDecoderModem` finds nothing.

- [ ] **Step 5: Commit.** Message: `feat(ui): multi-signal modem panel with cursor bench; remove phase-1 modem framework`.

---

### Task 17: Performance and live-band verification

**Files:**
- Create: `docs/superpowers/verification/2026-10-20-modems-verification.md`
- Test: `Tests/ModemsTests/ModemEnginePerformanceTests.swift`

- [ ] **Step 1: Write the performance test.**

  `thirtyPSKDecodersRealtimeHeadroom`
  - Input: 60 s of 12 kHz audio containing 30 PSK31 signals, decoded through `ModemEngine`.
  - Expect: it completes in < 6 s of wall time, i.e. ≥ 10× real time.
  - Mark the test `.enabled(if:)` for release builds only, or skip it in debug with a message.

- [ ] **Step 2: Measure CPU in the release app.**

  1. Build the bundle with `scripts/bundle.sh`.
  2. Use the Demo source at 2 MSPS with FFT 8192 and the modem on PSK31 with auto-detect.
  3. Sample with `top -l 5 -pid <pid> -stats cpu`.
  4. Record the result in the verification doc against the target of < 30%.
  5. Record the 10 MSPS figure for information.

- [ ] **Step 3: Run the live-band check.**

  Use the RSP1B with HamItUp enabled. The controller or the user drives the UI. Tune each frequency, leave it 2–5 minutes, and record what decoded, with timestamps:

  | Mode | Frequency |
  |---|---|
  | FT8 | 14.074 USB |
  | WSPR | 14.0956 dial |
  | PSK31 | 14.070 |
  | CW | 14.030 |
  | RTTY | 14.085 |

  Also record:
  - the clock warning state
  - whether the box drag, re-center, cursor lock, Esc unlock, narrow/wide audio and bench all behaved as specified
  - an empty band, recorded as such rather than treated as a failure

- [ ] **Step 4: Commit.** Message: `docs: modem performance and live-band verification`.

---

## Self-review notes

- **Spec coverage:**

  | Spec section | Task(s) |
  |---|---|
  | §5.1 box | 2, 15 |
  | §5.2 cursor | 9, 15 |
  | §5.3 audio | 9, 14 |
  | §5.4 auto | 8, 9 |
  | §6.1 flow | 1, 14 |
  | §6.2 tracker | 4 |
  | §6.3 streaming | 5–7 |
  | §6.4 slots | 10–12, plus ClockCheck in 14 |
  | §6.5 classifier | 8 |
  | §6.6 framework | 3, 16 |
  | §6.7 bench | 9, 16 |
  | §7 UI | 13, 15, 16 |
  | §8 constraints | 14, 17 |
  | §9 tests | 4–13 |
  | §9a live | 17 |
  | Live-only FT8/WSPR | 15, 16 |

- **Type names are stable across tasks:**
  - `ModeID`, `ModemSettings`, `SignalSnapshot`, `DecodedText`, `SlotDecode`
  - `SignalDecoder`, `StreamingModem`, `SlotModem`, `ModemCatalog`
  - `Track`, `Classification`, `CursorFrame`, `ModemOutput`, `SlotJob`
  - `DecodeLog`, `DecodeRow`, `ModemBox`, `ModemChannel`, `FractionalResampler`
