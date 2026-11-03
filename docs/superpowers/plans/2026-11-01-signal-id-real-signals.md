# Signal ID on Real Signals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Signal ID finds, separates and names real signals on a real band: FT8, FT4 and RTTY/FSK first, with SSB voice and CW no worse, and accuracy scored on real recordings.

**Architecture:** A new front end in the `SignalID` module looks at the point's neighbourhood over time, finds traces, bounds each signal and groups traces into signals, then measures each signal alone. Evidence from UTC slots, an interference comb detector and (in the app layer) trial decodes feeds the existing mode table. The first build's measurer stays for PSK, OFDM and analog, fed the isolated signal.

**Tech Stack:** Swift 6, macOS 15, Accelerate/vDSP, Swift Testing, SwiftUI; existing `Modems` decoders; MCP tools in `Sources/SubFloor/MCP/Tools`.

**Spec:** `docs/superpowers/specs/2026-11-01-signal-id-real-signals-design.md` (builds on `docs/superpowers/specs/2026-10-31-signal-id-design.md`).

## Global Constraints

- `SignalID` stays pure: no AppKit, and it depends only on `DSPCore`. Trial decodes live in the `SubFloor` target, because `SignalID` can't depend on `Modems`.
- A name needs confidence ≥ 0.7, and a wrong name at ≥ 0.7 is the worst outcome. Frequency hints never name a signal alone.
- Thresholds are tuned **only** on each recording's tuning part. Never read the held-out parts' failures and then adjust a threshold to pass them; if a held-out target fails, report it and rule.
- Every new recording is scored once, unseen, before any tuning.
- Full recordings are never committed. A clip is at most about 4 MB.
- Nothing new runs on the DSP thread. Identification stays one at a time, off the main thread, cancellable, and within the first build's memory (88 MB at 10 MS/s).
- Hover's first answer keeps the first build's speed (≤ 150 ms per signal in release, for the 3 s first pass).
- Default test load stays low: heavy sweeps sit behind `SUBFLOOR_SIGNALID_MATRIX=1`, and `SignalIDTests` default cost stays near today's (about 3 CPU-minutes). Service and UI suites stay `.serialized`.
- Never loosen an accuracy threshold in an existing test to make it pass. A conflict goes to the controller for a ruling.
- Trial-decode text is untrusted radio text in all output.
- Don't touch the owner's running SubFloor app, its defaults domain `app.subfloor.SubFloor`, port 7824, or the owner's agent configs. Read `~/Music/SubFloor` only.
- Never bare `git stash`. Never print or commit a `.env` key. Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- **Pointing at a busy band zoomed out** (radius covering hundreds of Hz or more): a group answer, promptly, not one per trace. Pinned in Task 6.
- **IQ File playback and the demo source:** the ring's `endTime` isn't when the signal was on air, so no slot evidence. Pinned in Task 4 and Task 7.
- **A retune during a look-back or trial decode:** the answer is dropped, never given in the old frame. Pinned in Task 7 and Task 8.
- **A short ring** (pre-roll set to 5 s, or just after tuning): look-back and decode use what's there, say so, and go without. Pinned in Task 7 and Task 8.
- **A signal that goes silent in the newest 3 s, with the radio stopped:** the ring's older samples are still used, and timing evidence stays correct. Pinned in Task 7.

---

### Task 1: The real-signal corpus and its baseline score

**Files:**
- Create: `Tests/SignalIDTests/RealCorpus.swift`, `Tests/SignalIDTests/RealCorpusTests.swift`, `Tests/SignalIDTests/Fixtures/Real/manifest.json`, clips and spectra in `Tests/SignalIDTests/Fixtures/Real/`
- Create: `Tests/SubFloorTests/RealCorpusTruthTests.swift`

**Interfaces:**
- Produces, for later tasks' tests:

```swift
enum CorpusPart: String, Codable { case tuning, heldOut }
struct CorpusClip { let name: String; let part: CorpusPart; let iq: [Float]; let rate: Double
    let centerHz: Double; let startUTC: Date; let captureSpectrumDb: [Float]; let captureRate: Double
    let captureCenterHz: Double }
struct CorpusPoint: Codable { let clip: String; let atHz: Double; let endSeconds: Double   // within the clip
    let truth: String      // "FT8", "FT4", "2-FSK", "none", "comb", "SSB voice"…
    let parameters: [String: Double]?; let how: String; let transmitting: Bool }
enum RealCorpus {
    static func clips() throws -> [CorpusClip]
    static func points(_ part: CorpusPart?) throws -> [CorpusPoint]
    /// Runs `identify` as the hover does, and returns the share right per truth.
    static func score(_ part: CorpusPart?, identify: (CorpusClip, CorpusPoint) -> SignalIdentity) throws -> [String: (right: Int, total: Int)]
}
```

- **Clips:** stereo 16-bit WAV at 62.5 kS/s, at most 16 s each. From the 14 MHz recording, centre 14.0775 MHz: 0–16 s tuning, 16–32 s and 32–40.7 s held out. From the 11.7 MHz recording, centre 11.688 MHz: 0–12 s tuning, 12–24 s held out. Each recording's whole-capture average spectrum (32 768 bins, as `.bin` Float32) is saved per part, because lumping and the comb depend on the whole capture.
- `startUTC` comes from the file name (`SubFloor_YYYYMMDD_HHMMSSZ_…` is the first sample's time) plus the clip's offset.

- [ ] **Step 1: Write `RealCorpusTests.manifestIsSound`:** every point names a real clip and a time inside it; every clip is under 4.2 MB; both parts exist for each recording. Fails: no manifest.
- [ ] **Step 2: Add a gated clip maker.** `RealCorpusTests.makeClips`, enabled by `SUBFLOOR_SIGNALID_MAKE_CLIPS=1`, reads `~/Music/SubFloor/SubFloor_20261101_181844Z_14024000Hz_IQ.wav` and `SubFloor_20261101_184142Z_11733100Hz_IQ.wav` (1 MS/s; find the `data` chunk; don't assume offset 44), cuts clips with `Channel.extract`, and writes them and the spectra to the Fixtures folder (found from `#filePath`). Run it once, and commit what it writes.
- [ ] **Step 3: Establish the truth, by analysis separate from the code under test.**
  - **FT8:** `RealCorpusTruthTests` (in `SubFloorTests`, for `Modems`) SSB-demodulates each clip around the group and runs `FT8Modem.decode` on slots at 18:18:45, 18:19:00 and 18:19:15 UTC. Each decode gives a trace's frequency and proves FT8. Record any decode found. If none decode, tell the controller.
  - **FT4 and the FSK:** points from the design's hand analysis: tones and on-times by spectrogram. Confirm the FSK speed by a second method (a keying line from the demodulated frequency's squared change, over the whole recording); record in `how` whether it confirmed 75 Bd to 1%, and the value.
  - **Empty points:** at least 5 per clip, verified on a spectrogram as ≥ 500 Hz from any trace.
  - **Comb points:** the lines nearest the FT8/FT4 clip (about 14.0769 and 14.0780 MHz). Don't assert they are a comb until `InterferenceComb` proves it (Task 5).
  - **Neighbour:** the strong signal near 11.6859 MHz, truth `"not FSK"`.
  - **Windows:** points step every 3 s along each trace; `transmitting` true only with the signal on during the window's last 3 s.
- [ ] **Step 4: Write `RealCorpusTests.baselineScore`,** which prints the score per truth and per part with today's `SignalIdentifier.identify` (with `spectrumDb` from the saved capture spectrum cut to the clip's span), asserting nothing. Save the printout in the task report: the before picture.
- [ ] **Step 5: Add the gated full-recording test.** `RealCorpusTests.fullRecordings`, enabled by `SUBFLOOR_SIGNALID_REAL=1`, identifies the same points through the 1 MS/s read path, reading from `~/Music/SubFloor`.
- [ ] **Step 6:** Run `swift test --filter RealCorpusTests`. Expected: PASS, baseline printed.
- [ ] **Step 7:** Commit `test(signal-id): a corpus of real signals, with its baseline score`.

### Task 2: Look around the point: traces, and an honest "No signal"

**Files:**
- Create: `Sources/SignalID/Neighbourhood/TimeFrequencyMap.swift`, `Sources/SignalID/Neighbourhood/TraceFinder.swift`
- Modify: `Sources/SignalID/Identify.swift` (the seed section of `identify(iq:…)`), `Sources/SignalID/Measure.swift` (a given width isn't grown), `Sources/SignalID/SignalSynth.swift`
- Test: `Tests/SignalIDTests/TraceFinderTests.swift`, `Tests/SignalIDTests/RealCorpusTests.swift`

**Interfaces:**
- Consumes: `Channel.extract`, `RealCorpus`.
- Produces:

```swift
struct TimeFrequencyMap {
    let binHz: Double; let hopSeconds: Double; let lowerOffsetHz: Double   // relative to the capture centre
    let rows: Int; let bins: Int
    /// Power over that moment's own noise level, in dB, row by row.
    let relativeDb: [Float]
    static func build(_ z: [DSPComplex], rate: Double, centerOffsetHz: Double, binHz: Double, hopSeconds: Double) -> TimeFrequencyMap
}
struct SignalTrace: Equatable { var lowerHz, upperHz: Double   // relative to the capture centre
    var snrDb: Double; var onTimes: [ClosedRange<Double>]      // seconds within the read
    var steady: Bool }
struct OccupiedArea: Equatable { var lowerHz, upperHz: Double; var snrDb: Double; var onTimes: [ClosedRange<Double>] }
struct NeighbourhoodView { var traces: [SignalTrace]; var areas: [OccupiedArea]; var noiseDb: Double }
enum TraceFinder { static func find(_ map: TimeFrequencyMap) -> NeighbourhoodView }
```

- `SignalIdentifier.identify(iq:sampleRate:captureCenterHz:atHz:bandwidthHz:spectrumDb:longer:)` gains `pointRadiusHz: Double = 60`. Keep existing call sites compiling.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func emptyPointsSayNoSignal() // corpus, tuning part only, truth "none":
    // share right ≥ 0.95, and every answer's width ≤ 100_000
@Test func levelJumpIsNotASignal()  // synth: noise with a 6 dB step across the band → no trace, no area
@Test func twoCarriersAreTwoTraces() // synth: carriers 300 Hz apart → 2 traces
@Test func ft8ToneHopsStayInOneTrace() // synth FT8: 1 trace, width within 40…70 Hz
@Test func voiceIsAnArea()           // the real voice fixture: an area, width 2…3.2 kHz, no spurious traces
@Test func givenWidthIsNotGrown()    // identify(bandwidthHz: 900) at the corpus FSK: |occupied| ≤ 1100 and the strong neighbour is excluded
@Test func noSearchBeyondTheRadius() // strong carrier 2 kHz from an empty point, radius 60 → "No signal"
```

  Add `levelStep(atSeconds:db:)` to `SignalSynth`. Held-out empty points are asserted by `RealCorpusTests.heldOutTargets`, added here for the `"none"` truth; the row grows in later tasks.
- [ ] **Step 2:** Run `swift test --filter 'TraceFinderTests|RealCorpusTests'`. Expected: FAIL.
- [ ] **Step 3: Implement the map and finder.** Normalise each row by its own median, in the neighbourhood (±24 kHz of the point, the existing `localWindowHz`). Pick resolutions so a 3 s read fits the speed constraint.
- [ ] **Step 4: Replace the seed in `identify(iq:…)`.**
  - Nothing in the radius and no area around the point gives the existing `No signal`/`Too weak` answers.
  - Only a point inside an `OccupiedArea` or within the radius of a `SignalTrace` is measured, over that extent.
  - A width over 48 kHz needs positive evidence: the app's spectrum shows flat-topped occupancy with sharp edges (fall of ≥ 15 dB within 2% of the width on each side). Otherwise it's bounded to what the neighbourhood shows. WFM and DAB tests must still pass.
  - `SignalMeasurer.measure` treats the width as a ceiling when an agent gave one or when the trace finder bounded it; it may not merge across a gap to a neighbour.
- [ ] **Step 5:** Run `swift test --filter SignalIDTests`. Expected: PASS, including all existing family and real-voice tests. A family test that fails is a real regression: fix it, or ask for a ruling.
- [ ] **Step 6:** Commit `feat(signal-id): traces and areas around the point, and "No signal" when nothing is there`.

### Task 3: FSK from its tones

**Files:**
- Create: `Sources/SignalID/Neighbourhood/SignalGrouper.swift`, `Sources/SignalID/Features/DirectFSK.swift`
- Modify: `Sources/SignalID/Identify.swift`, `Sources/SignalID/Measure.swift`, `Sources/SignalID/ModeTable.swift`, `Sources/SignalID/SignalSynth.swift`
- Test: `Tests/SignalIDTests/DirectFSKTests.swift`, `Tests/SignalIDTests/RealCorpusTests.swift`

**Interfaces:**
- Consumes: `SignalTrace`, `TimeFrequencyMap`, `NeighbourhoodView`.
- Produces:

```swift
struct SignalCandidate: Equatable { var kind: Kind; var lowerHz, upperHz: Double; var traces: [SignalTrace]
    enum Kind: Equatable { case single, fsk(tones: [Double]), area } }
enum SignalGrouper {
    /// Lines whose power takes turns are one FSK signal; lines that ignore each other stay apart.
    static func group(_ view: NeighbourhoodView, map: TimeFrequencyMap) -> [SignalCandidate]
    static let turnsCorrelation: Float   // tuned; the real FSK measured about −0.5
    static let maxShiftHz = 1_500.0
}
struct FSKReading: Equatable { var toneCount: Int; var shiftHz: Double?; var spacingHz: Double?
    var baud: Double?; var baudConfidence: Float; var snrDb: Double }
enum DirectFSK { static func measure(_ z: [DSPComplex], rate: Double, tonesHz: [Double], noiseDb: Double) -> FSKReading? }
```

- `ModeRow("RTTY", …)` needs a new requirement: the row names only with the hint inside the RTTY segments, or with readable decoded text (Task 8). Add `requiresHintOrDecode: Bool` to `ModeRow`, and `readableDecode: Bool = false` to `SignalIdentifier.identify(_:rfHz:)`; otherwise the row caps below `nameThreshold`.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func alternatingTonesAreOneSignal()  // synth RTTY 75/850 → one .fsk candidate, 2 tones
@Test func independentCarriersStayApart()  // two keyed carriers 850 Hz apart, independent keying → 2 candidates
@Test func fskWithFadingOnOneTone()        // synth 75/850, one tone fading 10 dB → still 1 candidate
@Test func fskBesideAStrongCarrier()       // synth 50/425 at 10 dB SNR, carrier +20 dB 2 kHz away → FSK, not merged
@Test(arguments: rttyCases) func directReading(c) // 45.45/170, 50/425, 75/850, 100/170 at 20 & 10 dB: rate ±1%, shift ±3%
@Test func realSNRIsPlausible()            // the corpus FSK: snrDb within 3…50
@Test func ttyOutsideHamBandsStaysFSK()    // synth 75/850 at 11.688 MHz: best == nil, label starts "2-FSK · 75"
@Test func rttyInHamSegmentIsNamed()       // synth 45.45/170 at 14.085 MHz: best?.name == "RTTY"
@Test func cornerCaseCWIsNotFSK()          // real CW-like synth with key clicks: stays CW
```

  `RealCorpusTests.heldOutTargets` gains the `"2-FSK"` row: right ≥ 0.8 of transmitting windows with shift ±3% and speed ±1% (±3% if Task 1 couldn't confirm 75 Bd to 1%), and the neighbour never merged. Add `fading(toneIndex:depthDb:)` to `SignalSynth`. Tune on the tuning part only.
- [ ] **Step 2:** Run `swift test --filter 'DirectFSKTests|RealCorpusTests'`. Expected: FAIL.
- [ ] **Step 3: Implement.** Group from each line's power over time. Measure `DirectFSK` on a channel around the tones that still holds noise, with neighbours notched out, so SNR has a real reference. Speed comes from tone-run lengths and the keying line, and must agree. Feed the reading into `SignalMeasurement` (`family: .fsk`, or `.mfsk` above 8 tones). A `.single` candidate goes through the existing measurer on the isolated signal; add what the measurer needs for noise (a guard band) rather than filtering it away.
- [ ] **Step 4:** Run `swift test --filter SignalIDTests`. Expected: PASS. Print the corpus FSK's score in the report.
- [ ] **Step 5:** Commit `feat(signal-id): FSK measured from its own tones, and tones that take turns are one signal`.

### Task 4: FT8 and FT4 apart, with UTC slots

**Files:**
- Create: `Sources/SignalID/Features/SlotEvidence.swift`
- Modify: `Sources/SignalID/ModeTable.swift`, `Sources/SignalID/Identify.swift`, `Sources/SignalID/SignalSynth.swift`
- Test: `Tests/SignalIDTests/SlotEvidenceTests.swift`, `Tests/SignalIDTests/RealCorpusTests.swift`

**Interfaces:**
- Consumes: `SignalTrace.onTimes`, `SignalMeasurement`.
- Produces:

```swift
struct SlotFit: Equatable { var periodSeconds: Double; var lengthSeconds: Double; var fit: Float }
enum SlotEvidence {
    /// How well on-times fit a slot grid, allowing for the clock being off by `clockToleranceSeconds`. Nil without a true time.
    static func fit(onTimes: [ClosedRange<Double>], readEnd: Date?, period: Double, length: Double) -> SlotFit?
    static let clockToleranceSeconds = 2.0
}
```

- `identify(iq:…)` gains `endTime: Date?`: when the read's last sample was on the air. Nil means no slot evidence. `SignalMeasurement` gains `slotFit: SlotFit?` (make `SlotFit` public and Codable).
- Rows: split `"FT8 / FT4"` into `"FT8"` (8 tones, 6.25 Bd, 6.25 Hz; slot 15 s, about 12.64 s on) and `"FT4"` (4 tones, 20.83 Bd, 20.83 Hz; slot 7.5 s, about 4.48 s on). Update every test, doc and tool mention of the old name.
- All `ModeHint`s allow for about 2 kHz of tuning error: `ModeHint` gains `toleranceHz` (default 2_000 for hints on narrow-mode dial frequencies and segments; broadcast bands unaffected).

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func ft8OnItsSlotsFits()       // on-times at :00.5–:13.1 and :15.5–:28.1 → fit ≥ 0.8 for 15 s, poor for 7.5 s
@Test func ft4OnItsSlotsFits()       // starts every 7.5 s, 4.5 s long → fit ≥ 0.8 for 7.5 s
@Test func clockTwoSecondsOffStillFits()
@Test func continuousSignalDoesntFit()
@Test func noTimeNoEvidence()        // readEnd nil → nil, and the name rests on the tones alone
@Test func timingAloneNeverNames()   // a 2-FSK at 170 Hz, keyed on FT8's slots: never FT8
@Test func ft8AndFT4AreToldApart()   // synth FT8 and FT4, 12 and 4.5 s reads: names exact, never each other
@Test func offsetBandStillHints()    // FT8 group 1.1 kHz low (14.0731 MHz): the hint still applies
@Test func ft8OutsideItsBandStillNamedWithSlots() // synth FT8 at 14.200 MHz with slot fit: named FT8
```

  `RealCorpusTests.heldOutTargets` gains `"FT8"` and `"FT4"` rows: named in ≥ 0.8 of transmitting windows with no decode (hover path), and no FT8 named FT4 or the reverse.
- [ ] **Step 2:** Run `swift test --filter 'SlotEvidenceTests|RealCorpusTests'`. Expected: FAIL.
- [ ] **Step 3: Implement.** Slot fit raises a match whose tones already fit; it can't lift a poor parameter score (keep the `hintFloor` rule). Read `slotSeconds` per row. FT8's tone hops mean a `.single` trace with a width of about 50 Hz is measured with the existing MFSK path on the isolated trace over its longest transmission.
- [ ] **Step 4:** Run `swift test --filter SignalIDTests`. Expected: PASS. Print the FT8/FT4 corpus score in the report.
- [ ] **Step 5:** Commit `feat(signal-id): FT8 and FT4 named apart, from their tones and UTC slots`.

### Task 5: The interference comb

**Files:**
- Create: `Sources/SignalID/Features/InterferenceComb.swift`
- Modify: `Sources/SignalID/Identify.swift`, `Sources/SignalID/Neighbourhood/TraceFinder.swift`, `Sources/SignalID/SignalSynth.swift`
- Test: `Tests/SignalIDTests/InterferenceCombTests.swift`, `Tests/SignalIDTests/RealCorpusTests.swift`

**Interfaces:**
- Consumes: the whole capture's average spectrum.
- Produces:

```swift
public struct CombInfo: Codable, Sendable, Equatable { public var spacingHz: Double; public var lineCount: Int }
enum InterferenceComb {
    static func detect(spectrumDb: [Float], sampleRate: Double) -> (info: CombInfo, lineOffsetsHz: [Double])?
    static let minimumLines = 8
}
```

- `identify(iq:…)` gains `captureSpectrumDb: [Float]?` and `captureRate: Double?` (the whole capture, even when `iq` is a channel). `SignalIdentity` gains `comb: CombInfo?`. Its `label` gives `Interference comb · 19.3 kHz spacing`.
- A steady trace on a comb line gets `comb` set, `best` nil. A keyed or modulated trace on the grid is treated normally.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func realCaptureHasTheComb()     // corpus 14 MHz spectrum: spacing within 19.0…19.5 kHz, ≥ 8 lines
@Test func realFSKCaptureComb()        // corpus 11.7 MHz spectrum: report what's found; assert no comb line lands on the FSK's tones
@Test func tooFewLinesIsNoComb()       // synth 5 lines → nil
@Test func channelledBroadcastsAreNotAComb() // synth 10 kHz-spaced modulated AM stations (≥ 12) → nil
@Test func keyedSignalOnTheGridIsNamed()     // synth CW on a comb line → not comb
@Test func combIgnoredByNoiseFloor()   // the noise level near a comb is within 2 dB of the level without it
```

  `RealCorpusTests.heldOutTargets` gains `"comb"`: labelled comb or `No signal`, never a mode name.
- [ ] **Step 2:** Run `swift test --filter 'InterferenceCombTests|RealCorpusTests'`. Expected: FAIL.
- [ ] **Step 3: Implement.** Find narrow lines by local contrast, then the spacing by autocorrelating line positions; check lines are similar in width and steady where a read is available. Comb lines are excluded from the local noise and from areas.
- [ ] **Step 4:** Run `swift test --filter SignalIDTests`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(signal-id): a comb of steady lines is labelled interference`.

### Task 6: Several signals under the point

**Files:**
- Modify: `Sources/SignalID/Identify.swift`, `Sources/SignalID/Neighbourhood/SignalGrouper.swift`, `Sources/SignalID/SignalSynth.swift`
- Test: `Tests/SignalIDTests/GroupAnswerTests.swift`, `Tests/SignalIDTests/RealCorpusTests.swift`

**Interfaces:**
- Produces, on `SignalIdentity`:

```swift
/// Filled when several signals lie under the point: each one's answer. Empty for one signal.
public var signals: [SignalIdentity]
/// A connected group of one slot mode: its whole span, relative to the capture centre.
public var groupSpanHz: ClosedRange<Double>?
```

- **Labels:** `FT8 · 9 signals · 14.0731–14.0755 MHz` (the spec's format, needing the absolute span, so `label` takes it from `groupSpanHz` plus a stored `captureCenterHz` on `SignalIdentity`); `Several signals: FT8 ×6, unknown ×2`.
- At most 3 of a group are fully measured in the first pass, the strongest first. The rest inherit their name only if they fit the same slot and width. Others read `unknown` until measured on the card or by an agent.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func wideRadiusOnAGroupDescribesIt() // synth 9 FT8 at 300 Hz spacing, radius 700 → label "FT8 · 9 signals · …", signals.count == 9
@Test func mixedSignalsAreCounted()         // 3 FT8 and a CW → "Several signals: FT8 ×3, CW ×1"
@Test func narrowRadiusNamesOne()           // same group, radius 30 on a trace → one signal, signals empty
@Test func oneSignalIsUnchanged()           // an existing RTTY synth: signals empty, label as before
@Test func wideRadiusStaysFast()            // release only, behind the timing gate: group answer on a 3 s read ≤ 300 ms
@Test func noPointlessWidthsInAGroup()      // no signal's width over 100 kHz in signals
```

  `RealCorpusTests.heldOutTargets`: a point at radius 345 Hz (the owner's zoom) on the FT8 group counts as right when the label names FT8.
- [ ] **Step 2:** Run `swift test --filter 'GroupAnswerTests|RealCorpusTests'`. Expected: FAIL.
- [ ] **Step 3: Implement.** Traces inside the radius that belong to a connected group of one slot mode describe the whole group, per the spec. Keep the first pass within the speed constraint.
- [ ] **Step 4:** Run `swift test --filter SignalIDTests`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(signal-id): the answer describes every signal under the point`.

### Task 7: The service: owner first, look-back, time and radius

**Files:**
- Modify: `Sources/SubFloor/App/SignalIDService.swift`, `Sources/SubFloor/App/AppModel.swift`
- Test: `Tests/SubFloorTests/SignalIDServiceTests.swift`

**Interfaces:**
- Consumes: `identify(iq:…)`'s `pointRadiusHz`, `endTime`, `captureSpectrumDb`, `captureRate`; `IQSnapshot.endTime` and `IQRead.endTime` (they exist); `AppModel.sourceKind`.
- Produces:

```swift
enum SignalIDPriority: Sendable { case owner, background }
func identify(atHz: Double, bandwidthHz: Double? = nil, radiusHz: Double? = nil, longerRead: Bool = true,
              priority: SignalIDPriority = .background,
              firstAnswer: (@MainActor (SignalIdentity) -> Void)? = nil) async -> SignalIdentity?
static let radiusPixels = 4.0   // hover and card: radius = 4 × Hz per pixel at the current zoom
static let notAtFrequencyNote = "The radio isn't at this frequency: the last tune failed"
```

- `endTime` is passed only when `sourceKind == .sdrplay`. Demo and IQ File get nil.
- The `Analysis` typealias changes to take the new parameters; update the test hooks.

- [ ] **Step 1: Write the failing tests** (the suite stays `.serialized`).

```swift
@Test func ownerGoesAheadOfQueuedWork()    // a background job running, one queued, then owner: owner runs next
@Test func newerHoverReplacesOlder()       // two queued hovers: only the newer runs; the older returns nil
@Test func ownerStopsBackgroundAtNextCheck() // a running background job is cancelled when the owner asks, and the owner's answer comes
@Test func oneAtATime()                    // the concurrent-run count never exceeds 1 (the existing check holds)
@Test func silentNewest3sLooksBack()       // ring: signal 10 s ago, silent now → not "No signal"; first answer says measuring
@Test func noSignalAfterLookingBack()      // ring: nothing in 16 s → "No signal", and cached for the point
@Test func stoppedRadioUsesTheRing()       // radio stopped: identifies from the ring; endTime is the samples', not now
@Test func shortRingSaysSo()               // 5 s ring: look-back uses 5 s, and the note says what it read
@Test func retuneDuringLookBackDropsIt()   // retune mid look-back → nil answer
@Test func filePlaybackGetsNoSlots()       // sourceKind .file and .synthetic: analysis gets endTime nil
@Test func radiusFollowsZoom()             // hover at 345 Hz/px asks 1380 Hz; 10 Hz/px asks 40 Hz
@Test func failedTuneNoteAfterGrace()      // IQ at the old centre: "Too soon" for the first 1 s, then notAtFrequencyNote; that note isn't cached
```

- [ ] **Step 2:** Run `swift test --filter SignalIDServiceTests`. Expected: FAIL.
- [ ] **Step 3: Implement the priority queue.** Replace the first-come executor with one that keeps owner and background lanes: the serial guarantee stays, queued owner jobs run first, and a new owner hover cancels older queued hovers. Cancel a running background job when the owner asks, and re-queue it only if its caller still waits; a scan's caller then retries that point. Hover and card pass `.owner`; `get_cursor`, its longer read, and scans pass `.background`.
- [ ] **Step 4: Implement look-back, time and radius.** When the first read finds nothing in the radius, read back up to 16 s (limited by the ring, and the retune barrier), showing the first answer as measuring. Pass `endTime` and the whole capture's spectrum through both read paths. Keep the channel-first reads and the 64 MB limit.
  - **The comb:** the service keeps `InterferenceComb.detect`'s result, refreshed no more than once every 5 s and cleared on a retune, from the app's spectrum. With no app spectrum (an agent with the display off), it works from the ring's newest read.
- [ ] **Step 5:** Run `swift test --filter 'SignalIDService|SignalIDUI'`. Expected: PASS.
- [ ] **Step 6:** Commit `feat(signal-id): the owner's requests go first; a silent moment isn't an empty frequency`.

### Task 8: Trial decodes

**Files:**
- Create: `Sources/SubFloor/App/SignalIDDecoding.swift`, `Sources/SignalID/Features/ReadableText.swift`
- Modify: `Sources/SubFloor/App/SignalIDService.swift`, `Sources/SignalID/Identify.swift`, `Sources/SignalID/ModeTable.swift`
- Test: `Tests/SubFloorTests/SignalIDDecodingTests.swift`, `Tests/SignalIDTests/ReadableTextTests.swift`

**Interfaces:**
- Consumes: `FT8Modem.decode(samples:sampleRate:slotStart:audioBand:)`, `PSK31Modem`/`RTTYModem`'s `makeDecoder(frequencyHz:sampleRate:)` and `process(_:)`, `StreamRecorder` chunked reads.
- Produces:

```swift
public enum ReadableText { public static func score(_ text: String) -> Float }   // 0…1: words, not noise
struct TrialDecode: Sendable, Equatable { var mode: String; var text: String; var strength: Strength
    enum Strength: Sendable { case checked, readable } }
enum SignalIDDecoding {
    /// nil: no decoder applies, or it found nothing. Never sees the decoder panel or decode history.
    static func attempt(for identity: SignalIdentity, atHz: Double, centerHz: Double,
                        chunks: SignalIDService.ChunkProvider, cancelled: () -> Bool) -> TrialDecode?
    static let ft8RingSeconds = 28.0
}
```

- `SignalIdentity` gains `decodedText: String?`. A checked FT8 decode at the signal's frequency sets confidence to 1 and names it, like `confirmedByDecode`. Readable text is evidence for RTTY or PSK31, and satisfies `requiresHintOrDecode`. Unreadable text changes nothing.
- `identify(…)` in the service gains `tryDecode: Bool = false`: the card and agent calls pass true; hover passes false. A background decode for a group's slot is cached per slot start and channel, so a scan decodes once.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func wordsScoreHigh()            // "CQ CQ DE K1ABC K1ABC PSE K" ≥ 0.7; weather text ≥ 0.7
@Test func noiseScoresLow()            // random Baudot and Varicode output ≤ 0.3
@Test func cypherScoresLow()           // 5-letter random groups ≤ 0.3
@Test func ft8DecodeConfirms()         // corpus or encoder FT8 in the ring, slot in reach: decodedText set, best FT8 at 1.0
@Test func ft8NoSlotInReachGoesWithout() // 10 s ring: no decode, the name from tones and slots stands, note says so
@Test func rttyReadableNamesOutsideHam() // RTTYEncoder text at 11.688 MHz → "RTTY", decodedText set
@Test func encryptedFSKStaysFSK()      // random-bits 75/850 at 11.688 MHz → "2-FSK", no decodedText
@Test func psk31Readable()             // PSK31Encoder text → PSK31, decodedText set
@Test func hoverNeverDecodes()         // tryDecode false: the decoder is never called
@Test func decoderPanelUntouched()     // running a trial changes neither the DecodeHistory nor modem settings
@Test func retuneDropsTheDecode()      // retune mid-decode → nil answer
@Test func scanDecodesASlotOnce()      // 6 traces in one slot → decode called once
```

- [ ] **Step 2:** Run the two filters. Expected: FAIL.
- [ ] **Step 3: Implement.** SSB-demodulate the signal's channel to 12 kHz audio: FT8 from the latest complete slot in reach, on the same executor at `.background` for agents and `.owner` for the card. Decode time doesn't block a new owner request: check `cancelled` between stages. All decode text is treated as untrusted.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat(signal-id): a private trial decode as proof, for the card and agents`.

### Task 9: The card, the tools, the docs

**Files:**
- Modify: `Sources/SubFloor/UI/SignalIDCard.swift`, `Sources/SubFloor/UI/SignalIDActions.swift`, `Sources/SubFloor/MCP/Tools/SignalTools.swift`, `Sources/SubFloor/MCP/Tools/RadioTools.swift`, `README.md`, `plugins/subfloor/skills/subfloor-radio/SKILL.md`, `plugins/subfloor/skills/subfloor-radio/references/tools.md`
- Test: `Tests/SubFloorTests/SignalIDUITests.swift`, `Tests/SubFloorTests/MCPSignalToolsTests.swift` (or the existing signal tool suite)

**Interfaces:**
- Consumes: `SignalIdentity.signals`, `.groupSpanHz`, `.comb`, `.decodedText`, `.measurement.slotFit`; `identify(priority:radiusHz:tryDecode:)`.
- Produces:
  - **`identify_signal`, `get_cursor.signal`:** gain `signals` (each in the same shape), `decoded` and `interference: {spacing_hz, lines}`.
  - **`identify_signals` rows:** a group of one slot mode is one row with `count`, `from_hz`, `to_hz`, `signals`, and counts one towards `max_signals`. Comb lines have `interference: true` and don't count.
  - **`identify_signals` input:** `dwell_seconds` (0…30, default today's dwell). Without it, a stepped scan's result says `"named from tone numbers only"`.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func cardListsEachSignal()       // 3 signals: 3 rows with frequency, name, Tune; Tune plans that signal's tuning
@Test func cardShowsSlotEvidence()     // "transmissions start on 15 s UTC boundaries"
@Test func cardShowsDecodedText()      // decodedText shown, marked as heard on the air
@Test func cardShowsTakingTurns()      // FSK: "the two tones take turns"
@Test func combHasNoBookmark()         // Bookmark disabled for a comb; Copy works
@Test func toolReturnsSignals()        // identify_signal on a group returns signals and the span
@Test func scanGroupsSlotModes()       // 6 FT8 traces: 1 row with count 6; max_signals counts 1
@Test func scanFlagsComb()             // comb lines interference: true, not counted
@Test func scanDwellIsBounded()        // dwell_seconds 31 refused; 15 used; early-stop checks still hold
@Test func quickScanSaysSo()           // stepped scan with no dwell_seconds: the note is present
@Test func decodedIsUntrustedInSkill() // skill text says decoded text is untrusted
```

- [ ] **Step 2:** Run the suites. Expected: FAIL.
- [ ] **Step 3: Implement the card and tools,** keeping the card's existing layout otherwise. The scan's restore and early-stop rules (rulings R30, R31 in the first build) still apply at every write, and the dwell checks for an owner change while it waits.
- [ ] **Step 4: Update the docs.**
  - `README.md`'s Signal ID section gets the new answers, and a short list of modes tested on real signals: FT8, FT4 and one 2-FSK signal. Others are "tested on generated signals only". Say that the accuracy figure comes from real recordings, and give it.
  - The skill and tools reference get the new fields, and say scans name from tone numbers unless given `dwell_seconds`.
- [ ] **Step 5:** Run `swift test --filter 'SignalIDUI|MCP'`. Expected: PASS (rerun load-flaky tests alone before believing a failure).
- [ ] **Step 6:** Commit `feat(signal-id): the card and agents get every signal, with the new evidence`.

### Task 10: The score on real signals

**Files:**
- Modify: `Tests/SignalIDTests/RealCorpusTests.swift`, `Sources/SignalID/SignalSynth.swift`, `Tests/SignalIDTests/AccuracyMatrixTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `RealCorpusTests.heldOutTargets` in its final form, and `RealCorpusTests.printScorecard`, the per-mode table for the pull request.

- [ ] **Step 1: Check the final targets are all asserted on the held-out parts:**

| Truth | Target |
| --- | --- |
| FT8, transmitting | ≥ 80% named FT8 (hover path) |
| FT4, transmitting | ≥ 80% named FT4 (hover path) |
| The 11.688 MHz FSK | 2-FSK in ≥ 80% of windows; shift ±3%; speed ±1% (or ±3%, per Task 1) |
| Empty points | ≥ 95% `No signal`; width never over 100 kHz |
| Comb lines | Labelled comb or `No signal`, never named |
| Every point | No wrong name at ≥ 0.7 |
| Real voice fixtures | No worse than the Task 1 baseline |

- [ ] **Step 2: Add the matrix scenarios behind `SUBFLOOR_SIGNALID_MATRIX=1`:** neighbours, fading, comb, level jumps and FT8 groups, each with no wrong names at 3 dB.
- [ ] **Step 3:** Run `swift test --filter RealCorpusTests`, then `SUBFLOOR_SIGNALID_MATRIX=1 swift test -c release -Xswiftc -enable-testing --scratch-path .build/release-testing --filter SignalIDTests`, then `SUBFLOOR_SIGNALID_REAL=1 swift test --filter fullRecordings`. Expected: PASS. A separate scratch path keeps `.build/release` (which the owner may be running from) untouched. A held-out target that fails goes to the controller for a ruling, not a threshold change.
- [ ] **Step 4: Note the default cost:** `SignalIDTests`' CPU time, against the about 3 CPU-minutes constraint.
- [ ] **Step 5:** Commit `test(signal-id): the score on real signals, and the new scenarios behind the matrix switch`.
