# SubFloor — Multi-signal Modems Design

Date: 2026-10-20
Status: Approved in conversation; pending builder check
Builds on: `docs/superpowers/specs/2026-10-19-subfloor-design.md` (phase 1, merged to `main`)

## 1. Intent

The user hunts the bands for interesting signals. They click a trace, zoom in, and try to work out what it
is. The modem system has to do two jobs at once:

1. **Decode everything.** Inside a 3 kHz slice of the band, decode every PSK31, RTTY and CW signal at the
   same time, plus FT8 and WSPR, which decode in timed slots. This matters most for PSK31 and Morse, where a
   segment is full of simultaneous QSOs.
2. **Analyse the one under the cursor.** Give the signal under the cursor a signal-identification bench and
   priority treatment. The user identifies modulation by eye, so the bench must show the audio waveform
   clearly.

Two things would make the user wince even if the code works: **poor decode** and **sloppy UI/UX**. Both
are first-class requirements here, not polish.

## 2. Goals

- Five modes: **PSK31** (BPSK31, plus QPSK31), **RTTY** (45.45 Bd, 170 Hz shift), **CW**, **FT8** and **WSPR**.
- Every mode decodes every signal inside the 3 kHz modem box, in parallel.
- Each decoded signal shows the **audio frequency of its subcarrier**.
- A **3 kHz modem box** on the spectrum. The user grabs and drags it into place. A **Re-center** button
  returns it to the middle of the view.
- **Cursor priority.** The signal under the cursor:
  - is the one you hear
  - is pinned at the top of the output
  - always gets a decoder, even below the detection threshold
  - feeds the analysis bench
- **Analysis bench** for the cursor signal: audio **waveform** (oscilloscope), **micro spectrum**
  (±100 Hz), and an **IQ display**.
- **Auto-detect toggle.**
  - On: SubFloor classifies each signal's mode and routes it to the right decoder.
  - Off: the user picks one modem and it decodes every signal in the box with that modem.
- Elegant, easy-to-read output, following the approved mockups:
  - layout A (one live row per signal)
  - with the large, clear font of mockup B
  - matching `.superpowers/brainstorm/82458-1792473151/content/modem-workspace.html`
- Decode-quality targets, enforced by automated tests (§9).

## 3. Non-goals (this phase)

- Transmitting in any form: TX, macros, logging or QSO automation.
- Modes other than the five above. The modem framework must still make adding modes easy (§6.6).
- PSK63/125, RTTY at other speeds or shifts, and FT4. The framework should allow them later.
- Decoding outside the modem box.
- More than one modem box.

## 4. Anti-goals

These are failures even if everything technically works:

- **Decodes that are noticeably worse than fldigi or WSJT-X** at the same SNR.
- **Garbage-text spam.** Noise must not fill rows with junk characters. PSK31 must use squelch/quality
  gating, and rows with no confident decodes stay empty or hidden.
- **Jumpy or cramped UI:**
  - rows reordering while you read them
  - text too small to read
  - the bench flickering
  - the box moving when you didn't mean it to
- **Blocking the audio or DSP thread** with decoding work, causing audio dropouts.

## 5. Interaction design (decided with the user)

### 5.1 The modem box
- **Definition.** A rectangle on the main spectrum, exactly 3 kHz of RF wide. It is defined by a **dial
  frequency** (the USB carrier) in display Hz. The box covers RF `dial + 300 Hz … dial + 3300 Hz`, which is
  the audio range 300–3300 Hz. A subcarrier's audio frequency is `RF − dial`, the same convention FT8 and
  PSK31 operators use. *(The 300 Hz offset is from the approved mockup.)*
- **Moving it.** It moves only when the user grabs it and drags. The grab handle is a tab on the top edge,
  labelled with the mode, as in the mockup. *(Making the whole top strip of the box a grab area is the
  builder's call.)* Clicking outside the box never moves it. A drag pans in RF and never retunes the
  hardware.
- **Position is absolute.** It is held as an RF frequency, independent of the listening VFO and of the
  hardware centre. If a retune moves the box outside the captured span, the box goes inactive. Decoding
  stops and the panel shows "Modem box is outside the captured band — Re-center".
- **Re-center** places the box's centre at the centre of the current spectrum view, clamped to the capture
  span.
- **Bookmarks.** The box dial persists in the session. Bookmarks don't store it in this phase *(my call)*.

### 5.2 The cursor
- **Locking.** Clicking inside the box (not on the grab tab) sets the **modem cursor** at that audio
  frequency. It snaps to the nearest tracked signal within ±25 Hz (or the mode's lock range) and locks on.
  An AFC loop keeps it centred as the signal drifts.
- **Clicking outside the box** keeps today's behaviour: it tunes the listening VFO.
- **Drawing.** The cursor is drawn in amber on the spectrum, with its audio frequency, as in the mockup.
- **Moving it.** ←/→ while a modem is active nudge the cursor to the previous or next tracked signal
  *(my call)*.

### 5.3 What you hear
- While the modem panel has an active mode and the cursor is locked, the speakers play **the cursor
  signal** through a narrow filter sized to the mode:

  | Mode | Filter width |
  |---|---|
  | PSK31 | 150 Hz |
  | RTTY | 400 Hz |
  | CW | 250 Hz |
  | FT8 | 100 Hz |
  | WSPR | 50 Hz |

  The tone plays at its natural audio pitch. *(The widths are my call.)*
- An **Audio: Narrow / Wide** control switches to the whole box's 300–3300 Hz audio.
- With the modem panel off (no mode selected), audio comes from the VFO receiver as in phase 1.
- Modem active but **no cursor locked**: the speakers play the **wide** box audio *(my call)*.
- **Unlocking** the cursor: press **Esc**, or click the locked cursor/row again *(my call)*. Switching the
  mode to Off also unlocks it.
- Audio-source handoff between the Receiver and the modem thread happens only when the mode changes
  between Off and on. Lock and unlock only change the filter on the modem side *(my call)*.

### 5.4 Auto-detect
- **On.** Every tracked signal is classified and sent to the matching streaming decoder (PSK31, RTTY or
  CW). FT8 and WSPR slot decoders run on every slot regardless. A signal claimed by an FT8 or WSPR decode
  is labelled with that mode.
- **Off.** Only the user-picked mode runs. Streaming modes decode every tracked signal. FT8 or WSPR decode
  every slot.
- **UI.** A toggle button in the modem control strip.
- **Mode segment while auto-detect is on** *(my call)*: the segment acts as the **fallback mode** for the
  cursor's signal while it is still unclassified. The cursor always gets a decoder: a classified signal
  uses its detected mode, otherwise it uses the fallback. Non-cursor unknown signals get no decoder. The
  grab tab reads "AUTO · 3 kHz". The narrow audio filter for an unclassified cursor uses the fallback
  mode's width.

## 6. Architecture

### 6.1 Data flow
```
DSP thread (existing):
  IQ → Receiver (VFO audio, unchanged)
  IQ → ModemChannel: NCO to box dial → decimate → USB channel 0–3.4 kHz → real audio @ 12 kHz
         → SPSC ring → Modem thread
Modem thread (new, one dedicated thread):
  12 kHz box audio → SignalTracker (FFT, peaks, tracks, SNR)
                   → per-signal StreamingDecoders (PSK31 / RTTY / CW instances)
                   → SlotRecorder (UTC-aligned) → background queue: FT8 (ft8_lib) / WSPR decoders
                   → Classifier (auto-detect)
                   → CursorAnalyzer (waveform, micro-spectrum, IQ) → CursorFrameStore
                   → cursor audio (narrow bandpass or wide) → 48 kHz → AudioOutput
                   → DecodeEvents → main thread (throttled 10 Hz) → ModemPanelModel (@Observable)
```
- **Sample rate.** The box audio is 12 kHz real, the rate ft8_lib expects. All other decoders work from it.
- **What the DSP thread does.** It only produces box audio. All decoding runs on the modem thread. The FT8
  and WSPR slot decodes, each a burst of heavy work, run on a background `DispatchQueue`. No decoder work
  happens on the IQ callback or the audio render thread.
- **Speaker audio.** When a modem is active, the AudioOutput is fed from the modem thread. When it is off,
  it is fed from the Receiver as today. A single producer feeds the audio ring at any moment. The switch
  happens through the engine's pending-config handoff.

### 6.2 SignalTracker
- **Analysis.** A 12 kHz FFT of 4096 points (≈2.93 Hz bins), with 50% overlap and exponential averaging.
  It finds peaks above an adaptive noise floor within 300–3300 Hz.
- **Tracks.** Each track carries:
  - an id
  - an audio frequency (refined by parabolic interpolation)
  - SNR in dB, measured in a 2.5 kHz reference bandwidth, the WSJT convention
  - occupied bandwidth
  - first-seen and last-seen times
  - a peak-shape fingerprint, which the classifier uses
- **Track lifecycle.**
  - Tracks associate frame to frame within ±(mode lock range).
  - A track goes **quiet** after 20 s with no energy and is **removed** after 2 minutes *(timings my call)*.
  - The UI keeps quiet rows dimmed.
- **RTTY.** Two peaks 170 ± 15 Hz apart with similar levels form one RTTY track, centred between the mark
  and space tones.
- **Cap.** At most 40 concurrent streaming decoders. When the cap is hit, the weakest non-cursor tracks are
  not decoded. The cursor's track is always decoded, even if the tracker hasn't confirmed it.

### 6.3 Streaming decoders (per signal)
Each instance does three things:
1. Mixes the 12 kHz audio down at its track frequency with an NCO.
2. Decimates to a mode-appropriate complex baseband rate.
3. Runs a mode decoder that emits characters with a confidence value.

- **PSK31:**
  - **Front end:**
    - Matched filter (raised cosine, 31.25 Bd).
    - Gardner symbol timing recovery.
    - A Costas carrier loop, which provides AFC.
    - Differential BPSK decode, then Varicode.
  - **QPSK31:** decoded with a K=5 Viterbi decoder.
  - **Squelch:** a metric based on how close each symbol lands to the ideal constellation points. Text is
    emitted only while the metric is above threshold, which suppresses garbage on noise.
  - **Detection:** the classifier distinguishes BPSK from QPSK by constellation clustering.
- **RTTY:**
  - **Front end:**
    - Mark and space filters at ±85 Hz.
    - Envelope detection, then ATC (automatic threshold correction).
    - Start-bit sync at 45.45 Bd, 1.5 stop bits.
  - **Decoding:**
    - ITA2/Baudot, with LTRS/FIGS shift handling.
    - Unshift on space (USOS) on by default.
  - **Polarity:** auto-detect inverted (reverse-shift) signals.
- **CW:**
  - Reuse `CWDecoderCore`, the scale-free version from phase 1, generalised to an arbitrary tone frequency
    and to a 12 kHz rate.
  - Each instance runs at its track's frequency.
  - The 2-dot character and 5-dot word gap thresholds from phase 1 stay as they are.

### 6.4 Slot decoders
- **SlotRecorder:**
  - Keeps the last 2.5 minutes of 12 kHz box audio, each sample stamped with UTC wall-clock time (the
    system clock).
  - At each slot boundary plus the slot length, plus a margin, it hands the slot's samples to the decoder
    on the background queue.
  - The UI shows a slot progress indicator.
- **FT8:**
  - Slots are 15 s, starting at :00, :15, :30 and :45 UTC.
  - Decoding uses **ft8_lib** (MIT licence), vendored as a C target in `Sources/CFT8`, with its licence file
    kept. The user approved this.
  - A decode carries its audio frequency, time offset, SNR and message text.
  - All messages in the box's audio range are reported.
- **WSPR:**
  - Slots are 2 minutes, starting on even minutes UTC.
  - The decoder is **written fresh in Swift from the public WSPR protocol description.** Do not port or
    copy GPL code from WSJT-X or wsprd.
  - **Pipeline:**
    1. Downconvert to complex at 375 Hz.
    2. Candidate search over ±150 Hz around 1500 Hz audio. WSPR's sub-band is 1400–1600 Hz; search the box
       range that overlaps it.
    3. Sync-vector correlation for time and frequency.
    4. 4-FSK soft symbols.
    5. De-interleave.
    6. Fano sequential decode of the K=32, r=1/2 convolutional code.
    7. Unpack the callsign, grid and power. Type 1 messages are required. Type 2 and 3 are the builder's
       call, so add them only if cheap.
- **Live radio only** (user decision). FT8 and WSPR run only with a live source (RSP1B or Demo). With an
  IQ-file source the slot decoders are disabled, and the panel says "FT8/WSPR need a live radio".
  Streaming modes work on every source.
- **Clock check.** If the system clock is off by more than 1 s (checked with an NTP query at startup), the
  panel warns that FT8 and WSPR need accurate time *(my call; if NTP is unavailable, skip the warning)*.

### 6.5 Classifier (auto-detect)
- **Inputs:** per-track features from the tracker and a short baseband capture.
  - occupied bandwidth
  - spectral shape: a single line, twin lines, sidebands at ±15.6 Hz, or a group of 8 tones at 6.25 Hz
    spacing
  - envelope on/off keying
  - constellation clustering
  - timing within the 15 s or 2 min UTC slots
- **Output:** one of PSK31 (B/Q), RTTY, CW, FT8, WSPR or *unknown*, with a confidence.
- **Unknown signals** get a row that says "—" with no decoder, but the bench still works on them.
- **Approach:** rule-based thresholds are acceptable. Accuracy is measured by tests (§9).

### 6.6 Modem framework (replaces phase 1's `Modem`/`ModemHost`)
- **Protocols:**
  - `StreamingModem`, with: `info` (id, name, lock range, listen filter width); `makeDecoder(frequency:sampleRate:) -> any SignalDecoder`
  - `SignalDecoder`, with: `process(audio)` returning decoded characters, the current frequency, and IQ/constellation points for the bench
  - `SlotModem`, with: `info`; `slotLength`; `decode(samples, slotStart) -> [SlotDecode]`
- **Registry:** `ModemRegistry` lists both kinds.
- **Adding a mode** stays "one folder plus one registry line". The README's "Adding a modem" section is
  updated to match.
- **Migration:** phase 1's single-signal `CWDecoderModem` and its view are removed, and CW moves into the
  new framework.

### 6.7 Cursor bench data
- `CursorAnalyzer` runs on the modem thread for the locked signal. It publishes into a `CursorFrameStore`
  (the same Mutex-snapshot pattern as `SpectrumFrameStore`) at 30 Hz:
  - **Waveform:**
    - the last ~40 ms of the narrow-filtered cursor audio
    - trigger-stabilised on a rising zero crossing, so the trace stands still
  - **Micro spectrum:**
    - ±100 Hz around the signal
    - high-resolution FFT (≥0.5 Hz bins), averaged
  - **IQ:**
    - PSK: the last ~128 symbol-sampled constellation points
    - all other modes: a decimated baseband IQ trail
    - fades older points
  - **Readouts:** frequency (0.1 Hz), SNR, detected mode and symbol rate.

## 7. UI

The UI follows the approved mockup `modem-workspace.html`.

- **Modem panel** (replaces the phase 1 modem panel). From the top:
  1. **Control strip:**
     - mode segmented control: CW, PSK31, RTTY, FT8, WSPR, or Off
     - **Auto-detect** toggle
     - **Re-center box** button
     - **Audio: Narrow/Wide**
     - signal count
     - box dial frequency
     - slot progress for FT8/WSPR when relevant
  2. **Bench:** three panes (waveform, micro spectrum, IQ) with readouts. The bench is collapsible.
     Use Canvas or Metal; smooth at 30 fps and never flickering.
  3. **Signal rows.** Each row shows, in order: audio frequency (Hz), mode, decoded text, SNR.
     - **Look:**
       - large monospaced text: 16 pt, and 18 pt for the cursor row
       - frequency in accent blue
       - the cursor row pinned at top in amber, with wrapping text and more history
     - **Order:**
       - sorted by audio frequency
       - **rows never reorder while visible**
       - new signals insert in frequency order
       - quiet rows dim and are removed after 2 minutes
     - **Text:**
       - each row keeps its last ~2 lines
       - text scrolls left as it arrives
       - full history is available by expanding the row (click it) *(my call)*
     - **FT8/WSPR rows:**
       - one row per decoded message
       - prefixed with HHMMSS UTC, with SNR and audio frequency
       - newest slot at the top of their group
       - capped at 200 lines
  4. **Selecting a row** locks the cursor to that signal.
- **Spectrum overlay:**
  - the box (green, grab tab, 300/3300 edge labels)
  - the amber cursor with its frequency
  - optional small ticks for tracked signals *(my call: thin blue ticks in the ruler)*
- **Status:** the panel shows the box-outside-span message and the clock warning when relevant.

## 8. Constraints

- All phase 1 global constraints apply: Swift 6, macOS 15 deployment, no locks or allocation on the IQ
  callback or audio render, dark by default, and the rest.
- **CPU:** under 30% of one core for the **whole process** in a release build, at 2 MSPS with FFT 8192,
  with 30 active PSK31 decoders plus FT8 running *(my call on the conditions)*. Measured, and the result
  recorded in the plan's verification step. Also record the 10 MSPS figure, for information only.
- ft8_lib is vendored with its MIT licence. No GPL code anywhere.
- UTC slot timing uses the system clock.

## 9. Decode-quality targets (tests)

### SNR measurement
SNR is in a 2.5 kHz noise bandwidth (WSJT convention). Each test generates a synthetic signal plus AWGN at
12 kHz with a deterministic seed.

### Targets

| Mode | Signal | SNR | Pass criterion |
|---|---|---|---|
| PSK31 (BPSK) | — | −10 dB | ≥ 95% character accuracy |
| PSK31 (BPSK) | — | +10 dB | 100% |
| RTTY | 45.45 Bd, 170 Hz | −5 dB | ≥ 95% |
| CW | 20 WPM | −8 dB | ≥ 95% |
| FT8 | — | −20 dB | ≥ 80% of messages decoded |
| WSPR | — | −28 dB | ≥ 80% of messages decoded |

- **FT8 and WSPR shortfall** *(my call: the same rule for both)*. If ft8_lib can't reach −20 dB, or the
  Swift WSPR decoder can't reach −28 dB, the builder records the achieved threshold and flags it. Never
  weaken a test silently. For WSPR the gating test is ≥ 80% at −26 dB, with −28 dB as the tracked stretch
  goal.
- **Acceptance.** The §9 table is the acceptance definition of "not noticeably worse than fldigi/WSJT-X".
  A side-by-side comparison against those programs is optional and manual *(my call)*.

### Other required tests
- **Parallel decode:** five PSK31 signals at different audio frequencies plus two CW signals, all decoded
  simultaneously and correctly.
- **No garbage:** 60 s of noise with no signal produces no decoded characters in any streaming mode.
- **Classifier:** at +5 dB, each mode's synthetic signal is classified correctly in ≥ 90% of trials.
- **Box maths:** box dial, edges and the audio↔RF mapping.
- **Upconverter:** the box maths holds with the upconverter enabled.

### Encoders for tests
Each mode's test needs its encoder:
- **PSK31:** Varicode and BPSK modulator.
- **RTTY:** FSK modulator.
- **CW:** the existing Morse timeline.
- **FT8:** the ft8_lib encoder.
- **WSPR:** a Swift encoder written from the protocol description, which also validates the decoder by
  round trip.

## 9a. Live verification (user decision)

The user's RSP1B is connected with the HamItUp upconverter enabled, so live-band checks are part of
verification. With the upconverter on, tune the standard watering holes:

| Mode | Frequency |
|---|---|
| FT8 | 14.074 or 7.074 MHz USB |
| PSK31 | 14.070 MHz |
| WSPR | 14.0956 or 7.0386 MHz dial |
| CW | 14.000–14.060 MHz |
| RTTY | 14.080–14.090 MHz |

The verification step records:
- what decoded live
- the clock-offset warning state
- CPU use

Live results depend on propagation, so an empty band is recorded as such, not counted as a failure. The
synthetic tests in §9 are the hard gate.

## 10. Left to the builder

- FFT sizes, loop bandwidths and threshold constants, within the targets.
- Rendering technology for the bench (SwiftUI Canvas or Metal), as long as it is smooth and flicker-free.
- How to vendor ft8_lib: the git commit pinned and recorded in the code, with the license file kept.
- Whether to support WSPR type 2 and 3 messages, and RTTY reverse-shift auto-detect versus a manual toggle.
- Internal file layout within the existing module structure (`DSPCore`, `Modems`, `SubFloor`).
