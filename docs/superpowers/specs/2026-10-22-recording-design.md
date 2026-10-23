# Audio & IQ recording with a rolling pre-roll — Design

Date: 2026-10-22
Status: Built from the request in an unattended session; the calls below are the builder's and are
open to change.

## 1. Intent

Capture what the receiver hears (demodulated audio) and what the radio sees (baseband IQ), either one
or both, with one click, as lossless files. The save buffer is always running: a recording started
now also contains the last 5–120 s, so a signal that has already begun when the user reaches for the
button is not lost.

## 2. Behaviour

- **Three quick actions** in the top bar: `Audio`, `IQ`, `Both`. Each is a toggle; red while
  recording, showing the elapsed time. `Both` starts whichever is off, or stops everything when any
  is on. Menu items with ⌘⇧A, ⌘⇧I, ⌘⇧R, and "Show Recordings in Finder".
- **Pre-roll.** One slider (5–120 s, default 30 s) for both streams. Each stream keeps a ring of its
  most recent samples in RAM, always, while the radio runs. A recording starts at the oldest
  available sample up to the pre-roll length; the file name's timestamp is that first sample's time.
  While idle, the buttons' faint fill shows how much pre-roll is primed.
- **Audio** is the Receiver's output after AGC and squelch, *before* the volume knob and the soft
  limiter, 48 kHz mono: the level is independent of the volume setting.
- **IQ** is the capture stream at the source rate (0.0625–10 MSPS), as stereo I/Q. A retune of the
  capture centre rolls to a new file (one centre per file) and clears the IQ pre-roll (samples at the
  old centre are useless); VFO moves inside the span do not. Stopping the radio finalises any open
  recording.
- **Files**, lossless only:

  | Stream | Container | Sample formats | Notes |
  |---|---|---|---|
  | Audio | WAV | 16-bit, 24-bit, 32-bit float | RIFF PCM / IEEE float |
  | Audio | FLAC (default, 24-bit) | 16-bit, 24-bit | Apple's encoder (AudioToolbox) |
  | Audio | Apple Lossless (.m4a) | 16-bit, 24-bit | AudioToolbox |
  | IQ | WAV (default, 16-bit) | 16-bit, 32-bit float | SDR#-style name; readable by SubFloor's own IQ file source |
  | IQ | SigMF | 16-bit (`ci16_le`), 32-bit float (`cf32_le`) | `.sigmf-data` + `.sigmf-meta` with rate, centre, UTC time |

  16-bit IQ is lossless for the RSP1B (14-bit ADC). Integer conversion rounds, no dither.
  WAV files roll to a new file just under 4 GiB. WAV headers are patched every 2 s so a crash leaves a
  playable file.
- **Names**: `SubFloor_20261022_143000Z_14074000Hz_USB.flac`, `SubFloor_20261022_143000Z_14100000Hz_IQ.wav`
  in `~/Music/SubFloor` (changeable in Settings).
- **Memory.** The IQ ring holds pre-roll + a write margin in the chosen sample format; a memory
  limit (default 2 GB, Settings) shortens the effective pre-roll at high rates, and Settings shows the
  resulting seconds. Audio's ring is small (≤ 23 MB).
- **Failure.** A write error (disk full, folder gone) stops that recording and shows a banner. If
  the writer falls more than the margin behind, the recorder skips to the oldest data it still has
  and counts an overrun in the status.

## 3. Architecture

New SwiftPM target `Recording` (depends on nothing but Foundation/Accelerate/AudioToolbox):

- `HistoryRing` — byte ring with one producer that always writes (overwriting the oldest) and one
  consumer that *rewinds* to a past position when a recording starts and follows from there. A
  mutex guards memcpy-only critical sections (uncontended; the DSP loop already takes a lock per block).
- `SampleFormat` / `FileFormat` — enums with the allowed combinations, byte sizes, extensions, and
  the float → int16 / int24 / float32 conversion (vDSP).
- `RecordingFile` — `WAVFile`, `SigMFFile`, `CoreAudioFile` (FLAC/ALAC through `ExtAudioFile`),
  all fed raw interleaved bytes in the chosen sample format.
- `StreamRecorder` — one per stream. `push(_ floats:)` on the DSP thread converts and appends to the
  ring. `start(in:context:)`/`stop()` from the main thread are commands to a writer thread, which
  rewinds, opens the file, drains the ring in 1 MiB chunks, rolls files, finalises, and publishes a
  `Status` (recording, first-sample time, frames/bytes, URL, pre-roll fill, overruns, error).
- `RecordingSettings` (Codable) — pre-roll seconds, formats, memory limit, folder.

App side: `DSPEngine` owns an IQ and an audio `StreamRecorder` and taps both on the DSP thread;
`AppModel` configures them, names files, exposes `toggleRecording(_:)`, polls statuses at 5 Hz, and
persists the settings in the session.

## 4. Non-goals

Lossy formats, scheduled or squelch-triggered recording, recording the modem's box audio, marking
dropped IQ in the file (the status counts the source's drops; the file is contiguous as received).
