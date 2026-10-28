# Auto-record on squelch, the Recordings timeline, and Dial scrubbing — Design

Date: 2026-10-26
Status: Approved 2026-10-26. Decisions marked **(user)** came from the owner; **(builder's call)**
marks a default chosen while designing that the owner has not ruled on, and may be changed.

## 1. Intent

Leave SubFloor listening to one frequency all day and come back to a tidy record of what happened.
The owner's usual targets:

- **HFGCS, 11.175 MHz USB.** Mostly dead air. Short, sporadic voice traffic (a Skyking call, an EAM
  of 20 s to a few minutes, often repeated). Static crashes and lightning pop the squelch all day.
- **Pirates, 6.925 MHz (USB/AM).** Evening shows of music and talk lasting up to a couple of hours,
  fading in and out with propagation.

Three parts, built in this order:

1. **Auto-record:** the squelch opening starts an audio recording; brief pops are ignored; a
   recording stays open through fades and closes after the channel has really gone quiet.
2. **The Recordings window:** a day timeline with a lane per frequency, markers for every recording,
   a waveform player to scrub through them, and a red badge counting unheard recordings.
3. **Dial scrub mode:** the SubFloor Dial scrubs the selected recording, with the jump size chosen
   on the Dial. Needs a firmware update in the `radiodial` repository as well as the app.

**Success:** after a day unattended, the Recordings window shows each real transmission as one
marker, none of the squelch pops, each clip begins before the first word, and each pirate show is
one file.

## 2. Goals, non-goals, anti-goals

Goals
- Audio-only auto-record triggered by the existing squelch. **(user: no IQ)**
- Short squelch breaks never make a file. **(user)**
- One long recording per transmission, through fades and pauses. **(user)**
- The squelched stretches inside a recording are silent, as the live audio is today. **(user)**
- The start of a transmission is never cut off by the decision delay (the rolling buffer). **(user)**
- A day timeline in a separate window with lanes per frequency, click-to-select markers, mouse
  scrubbing, and Dial scrubbing with jump sizes chosen on the Dial. **(user)**
- A red count of unheard recordings on the Recordings button, and a Clear button. **(user)**
- Fit for running all day.

Non-goals
- IQ auto-recording, or IQ files on the timeline (they stay in Finder).
- Scanning several frequencies (one receiver: auto-record follows wherever the radio is tuned).
- Editing, trimming, exporting or deleting recordings from the window (Finder does that; the window
  has "Show in Finder").
- Lossy formats; transcription; notifications outside the app.
- A squelch that adapts to the noise floor, or a cap/warning for a squelch held open by noise. The
  owner sets the threshold for the conditions (HF noise rises 10–20 dB at night) **(user)**.

Anti-goals (failure even if it "works")
- A timeline littered with 1-second clips of static. (An occasional longer file of storm crackle is
  fine — see §3.1.)
- A pirate show split into dozens of files, or an EAM and its repeat split mid-message.
- Clips that start mid-word, or long tails of silence after every clip.
- The app dying, the Mac sleeping, or the disk filling silently during an unattended day.

## 3. Auto-record behaviour

### 3.1 Trigger

The trigger reads the receiver's squelch gate (open or shut) every DSP block. Two settings in
Settings › Recording:

| Setting | Default | Range | Meaning |
|---|---|---|---|
| **Start after** | 2 s | 0.5–10 s | How much open squelch it takes to start a recording |
| **Stop after** | 30 s | 5 s – 10 min | How long the squelch must stay shut to end it |

(defaults: builder's guess, accepted by the user)

- **Arming.** While idle, the trigger watches for the gate opening. Once open, it counts open time.
  SSB speech drops the gate between syllables, so short dips do not reset the count: the count
  resets only if the gate stays shut longer than a **bridge** of 1.5 s **(builder's call)**. When the
  accumulated open time reaches *Start after*, a recording starts.
- **Ignored pops.** A run of gate activity that ends (shut longer than the bridge) before reaching
  *Start after* is logged as an ignored pop (time, frequency, length) for the timeline (§4.3), and
  makes no file.
- **Start point.** The file begins **0.5 s before the gate first opened** in that run **(builder's
  call)**, not at the moment the decision was made. The audio ring already holds this (the default
  30 s pre-roll ≫ *Start after* + 0.5 s). Reaching further back is pointless: the audio before the
  gate opened is silence. Consequence, accepted by the user: anything too weak to open the squelch is
  not recorded, exactly as it is not heard live.
- **Recording.** The gate may open and shut freely; the file keeps the silent gaps so playback is
  real-time. Any reopening, however short, restarts the *Stop after* countdown: reopenings do not
  have to qualify. A fading pirate show stays one file even when it comes back only in brief peaks.
  **(user: occasional files of storm crackle are acceptable; splitting a fading show is not.)**
  Likewise a fast run of static crashes may add up to *Start after* and start a file; that is
  accepted.
- **Stop point.** When the gate has been shut for *Stop after*, the recording ends at **2 s after
  the gate last shut** **(builder's call)**, not at the moment the decision was made. The file never
  carries the full *Stop after* of silence.
- **Retune or mode change** while recording ends the recording at that moment (the file is named for
  one frequency and mode) and the trigger starts over on the new frequency **(builder's call)**.
- **Radio stopped / source changed / app quitting** ends a recording at once, as manual recording
  does today.
- The trigger works with every source, including an IQ file played back, which also makes it
  testable with real HFGCS captures.

### 3.2 Getting the start and the end right without truncating files

`StreamRecorder` today starts at "now minus the pre-roll" and stops at "now". Auto-record needs:

- **Start at a given past moment.** The trigger runs on the DSP thread, right after the audio is
  pushed, and counts audio frames pushed to the audio recorder: that count is the ring position. A
  start command carries the frame the file should begin at (gate-open frame − 0.5 s); the recorder
  rewinds to it (clamped to what the ring still holds).
- **End at a given past moment without writing past it.** FLAC and ALAC files cannot be cheaply
  truncated, so an auto session must not write audio it may later trim. The writer for an auto
  session only drains up to a **committed** position that the trigger advances: while the gate is
  open, up to the head; while shut, no further than *gate-last-shut + 2 s*. If the gate reopens
  before *Stop after*, everything up to the head is committed (the silent gap is kept). On stop, the
  cut is the committed position. The audio ring must therefore hold *Stop after* + margin of audio as
  well as the pre-roll (10 min at 24-bit 48 kHz ≈ 86 MB; within the audio ring's existing 256 MB cap).
  Manual recording keeps its current behaviour.
- Exact API shape is the builder's; it lives in the `Recording` target and is unit-tested there with
  synthetic gate timelines.

The receiver must expose its gate state (`squelchOpen` is private today). The trigger itself should
be a pure state machine (`AutoRecordTrigger`: fed `(frames, gateOpen)`, emits start/commit/stop/pop
events with frame positions) so it is testable without audio.

### 3.3 Controls and states

Top bar record cluster becomes **Audio · IQ · Both · Auto · Recordings**.

- **Auto** toggles auto-record (also in the Radio menu, ⌘⇧T — builder's call). States:
  - *off*;
  - *armed* (listening): faint red ring;
  - *recording*: solid red with the elapsed time, like the Audio button;
  - *needs squelch*: the squelch is off, so nothing can trigger. Turning Auto on with squelch off
    shows a banner ("Auto-record needs the squelch on") and the button shows the state; Auto stays
    on and resumes when the squelch is turned on **(builder's call)**.
  - With the radio stopped, Auto stays on and resumes when the radio runs.
- **Manual and auto share the audio recorder.** If Audio is pressed while Auto is recording, that
  recording becomes manual (runs until Audio is pressed again); while a manual audio recording runs,
  the trigger is paused and resumes when it ends **(builder's call)**.
- **Persistence.** Auto on/off, *Start after*, *Stop after*, and the squelch enable and threshold are
  saved with the session, so after a relaunch the settings are as they were. (Squelch is not in
  `SessionState` today.) That is all: SubFloor does not relaunch itself after a crash or reboot and
  does not start the radio at launch **(builder's call)**; the target is "running all day", not
  surviving reboots.
- **Never record the demo source.** If the radio falls back to the synthetic source (e.g. the RSP
  fails to open), Auto shows a "not on a real radio" state and does not trigger **(builder's call)**.
  IQ file sources do trigger (for testing).

### 3.4 Unattended running

- While Auto is on and the radio running, SubFloor holds a `ProcessInfo` activity that prevents
  idle system sleep (the display may sleep) **(builder's call)**.
- Disk: each auto start checks free space; under 500 MB shows the existing warning banner; under
  100 MB Auto turns itself off with an error banner and a log entry, rather than failing on every
  transmission **(builder's call)**.
- A write error ends that recording with a banner (existing behaviour); Auto stays armed.
- Files use the existing audio settings (FLAC 24-bit by default), names and folder. Auto files are
  named exactly like manual ones; auto vs manual is recorded in the log (§4.3) **(builder's call)**.

## 4. The Recordings window

### 4.1 Opening it

- A **Recordings** button at the end of the record cluster opens a separate window
  (`Window("Recordings", id: "recordings")`), also from the Radio menu ("Recordings…", ⌘⇧L —
  builder's call). "Show Recordings in Finder" stays.
- The button carries a **small red badge** with the number of unheard recordings across all days
  (hidden at zero; "99+" above 99). **(user)**

### 4.2 Layout (user picked "Lanes" from the mockups)

Mockup: `.superpowers/brainstorm/65286-1793062814/content/day-timeline.html` (option B, and the
player). Dark, matching SubFloor's spectrum palette.

- **Header:** the day (UTC), ‹ › arrows to step days, "Today", the unheard count, **Clear**, and
  "Show in Finder".
- **Timeline:** 00–24 h UTC across the window with hour ticks (labels every 3 h). One **lane per
  frequency** that has recordings that day, labelled `11.175 MHz USB`; lanes appear as needed, sorted
  by frequency. A lane per frequency+mode pair if the same frequency was recorded in two modes
  **(builder's call)**.
- **Markers:** rounded glowing pills, width = duration (minimum width a few points so a 20 s clip is
  clickable), coloured per lane from a fixed palette (amber, cyan, green, …). Unheard markers are
  brighter with a small dot; selected marker glows. Manual recordings are drawn with an outline
  rather than a fill **(builder's call)**. Hover shows start time, length, frequency, mode.
- **Ignored pops row:** a faint row of dots at the bottom showing every ignored squelch pop that day,
  with a count, so the owner can see it was listening.
- **Now line:** a red line at the current time on today's view; a recording in progress grows live.
  It cannot be selected or played until it has ended (FLAC/ALAC files are not readable until
  finalised, and the auto writer holds back up to *Stop after* of audio) **(builder's call)**.
- The days shown are UTC days (matches the file names and HF practice) **(builder's call)**.

### 4.3 Where the timeline's data comes from

- **Recordings:** scanning the recordings folder for SubFloor audio files (WAV, FLAC, .m4a) and
  parsing start time, frequency and mode from the name; duration from the file. Files deleted or
  moved in Finder disappear from the timeline. Files from before this feature appear as manual and
  heard.
- **Log:** a per-day JSON-lines file in a hidden subfolder of the recordings folder
  (`.subfloor/2026-10-26.jsonl` — builder's call) recording: auto recording started/ended (file,
  times), ignored pops, and "heard" marks. It is the only source for pops, heard state and
  auto/manual. Append-only; small.
- The window refreshes live while open (a new recording appears as it starts).

### 4.4 Heard / unheard

- New recordings (auto or manual) are **unheard**. A recording becomes **heard** when it is played
  (any playback start) **(builder's call)**.
- **Clear** marks every recording heard and the badge drops to zero. **(user)**

## 5. The player

Under the timeline; follows the selected marker.

- Title line: frequency, mode, start time, length; a large clock showing the playhead's **UTC time
  of day** to 0.1 s (`07:48:12.4Z`).
- **Waveform** of the whole recording (peaks computed in the background and cached per file; a
  1.5 h file must not freeze the window). Squelched stretches read as flat. For long recordings the
  waveform can be zoomed around the playhead (pinch / ⌘-scroll) so 0.1 s jumps are visible
  **(builder's call)**.
- **Mouse:** click or drag on the waveform moves the playhead; if playing, playback continues from
  there. Space plays/pauses; ← → move by the current jump.
- **Jump sizes:** 0.1 s, 0.5 s, 1 s, 5 s, 30 s, 5 min. Shown as chips in the window; the current one
  is chosen on the Dial (§6) and mirrored here (clicking a chip also sets it).
- **Audio routing:** playback **mutes the live radio audio** while playing; auto-record keeps
  running underneath and new recordings appear on the timeline (builder's guess, not contradicted).
  Live audio returns on pause/stop or when the window closes. Playback level follows the main volume
  knob **(builder's call)**.

## 6. Dial scrub mode

### 6.1 Behaviour (user: jump size is selectable on the Dial itself)

The Dial enters **scrub mode** while the Recordings window is the key window and a recording is
selected; it returns to tuning when the window closes or loses key status **(builder's call)**. In
scrub mode the Dial's existing step gestures are reused for the jump:

| Gesture | Scrub mode |
|---|---|
| Turn | Move the playhead by the current jump |
| Press | Next coarser jump (0.1 → 0.5 → 1 → 5 → 30 s → 5 min → 0.1) |
| Hold + turn | Pick the jump |
| Swipe left / right | Coarser / finer jump |
| Tap the screen | Play / pause (builder's guess: press is taken by the jump) |
| Long-press | Settings, as today |

The Dial screen shows the jump size, the playhead's UTC time, play/pause state and the recording's
frequency, with a progress ring around the edge. The ring colour differs from tune (amber) and
bandwidth (cyan) modes.

### 6.2 Protocol additions (exact syntax is the builder's)

SubFloor → Dial:
- `SCRUB on title=<freq/mode> len=<s> pos=<s> play=<0|1> jump=<s>` / `SCRUB off`;
- `POS <s> [seq]` (playhead, answering the Dial's move when `seq` given), `PLAY <0|1>`.

Dial → SubFloor:
- `J <seq> <n>` move `n` jumps; `JUMP <s>` jump size changed; `PLAY` toggle.

Same rules as tuning: the Dial predicts the playhead locally so its readout moves instantly and
ignores stale `POS` lines. Older firmware that does not know `SCRUB` must keep working: SubFloor
learns the firmware version from `HELLO` and does not send scrub lines to firmware that predates it.
`PROTOCOL.md`, the firmware (`radiodial/firmware/src`), `DialProtocol.swift` and
`DialController.swift` change together; the firmware version is bumped.

## 7. Testing

- `AutoRecordTrigger` unit tests: pops of 0.3–1.9 s make no recording and are logged; speech with
  syllable gaps under the bridge starts a recording at the right frame; fades shorter than
  *Stop after* keep one recording; the stop frame is last-shut + 2 s; retune ends a recording.
- `StreamRecorder` tests for start-at-frame and commit/stop-at-frame, including the writer never
  writing past the committed position and the clamp when the ring no longer holds the start.
- **First step of the build:** capture real IQ with the attached RSP1B, a few hours on 11.175 MHz
  (including static crashes) and an evening on 6.925 MHz (including fades), at a modest sample rate,
  outside the repository. The trigger defaults are tuned against these before the live run.
- End-to-end with an IQ file source (those captures, and synthetic bursts + noise) through the
  real `Receiver` squelch, asserting on files produced (not wall clock — the demo source runs slower
  than real time in debug builds).
- Timeline model tests: folder scan + log merge, UTC day bucketing, lanes, heard/unheard and Clear.
- Dial: protocol parse/format tests in `DialProtocolTests`; firmware checked on the device with
  `dialctl.py` (`SIM ENC`, `SIM CLICK`, `SIM TAP`, `--shot`).
- Live check on the RSP1B on 11.175 MHz USB for some hours.

## 8. Left to the builder

Everything marked **(builder's call)** above; exact APIs; the timeline's drawing technology
(SwiftUI Canvas is the expected choice); colours beyond the mockup; the log format; keyboard
shortcuts.
