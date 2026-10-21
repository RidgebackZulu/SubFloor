# SubFloor

A fast, native macOS (Apple Silicon) receiver for the SDRplay RSP1B: Metal spectrum + waterfall,
AM/NFM/WFM/USB/LSB/CW audio, HamItUp upconverter mode, bookmarks, and a multi-signal modem panel that
decodes every CW, PSK31, FT8 and WSPR signal in the receiver's passband at once.

## Requirements
- macOS on Apple Silicon, Xcode 26 / Swift 6.2
- [SDRplay API 3.15](https://www.sdrplay.com/api/) installed (`/usr/local/lib/libsdrplay_api.dylib`). The SDRplay API service must be installed and running, or the RSP cannot be opened (SubFloor then falls back to the demo signal; use Retry once it is up).

## Build & run
```bash
swift run -c release SubFloor        # run from source
scripts/bundle.sh                    # build build/SubFloor.app
swift test                           # unit tests
SUBFLOOR_HW=1 swift test             # also run the RSP1B hardware smoke test
```
Without an RSP connected, SubFloor runs on a built-in demo signal around 14.1 MHz.

## Using it
| Action | How |
| --- | --- |
| Tune | Click the spectrum · scroll a readout digit · click readout and type `14.074`, `7074k`, `144.39m` |
| Quick tune | ⌘L or `/` — frequency or bookmark name (`ft8 20`) |
| Run / Stop | Space or ⌘R |
| Open IQ recording | ⌘O (stereo I/Q WAV) |
| Reset zoom | ⌘0 |
| Step VFO | ← / → (⇧ ×10); with a modem mode on they move the modem cursor instead |
| Mode | Top bar, or `[` / `]` |
| Zoom / pan | Pinch or ⌥-scroll / two-finger scroll or drag — never retunes the radio |
| Bandwidth | Drag the passband edges |
| Bookmarks | ⌘D add · ⌘B show on spectrum · sidebar list |
| HamItUp | Top-bar button (green when on) or ⌘U (LO set in Settings, default 125 MHz) |
| Tune a bookmark | Click its flag above the spectrum: frequency, mode, passband width and HamItUp, at the current zoom |
| Edit a bookmark | Right-click (or ⌃-click) its flag: name, frequency, mode, bandwidth, group, HamItUp; Use Current Tuning, Tune or Delete |

## Modem panel
Pick a mode (CW, PSK31, FT8, WSPR) in the panel under the spectrum. The modem decodes what the receiver
is tuned to: its window is the receiver's passband (on USB, 300 Hz up to the passband's top edge, at
most 3300 Hz above the dial, which is the VFO), so you hear what is decoded, and the receiver's audio
keeps playing. Tune with the VFO as usual and widen or narrow the passband by dragging its edges; the
panel shows the band being decoded. Changing mode starts afresh: nothing of the old mode carries over.

| Action | How |
| --- | --- |
| Analyse a signal | Click it inside the passband: the amber cursor snaps to the nearest tracked signal and follows it; the bench shows its waveform, ±100 Hz spectrum and IQ. Clicking outside the passband still tunes the VFO |
| Analyse a decode | Click a row in the decode list (FT8/WSPR messages included): the cursor goes to that signal and the bench shows it; the row turns amber |
| Unlock the cursor | Esc, click the cursor again, or click its (amber) row |
| Next / previous signal | ← / → while a mode is on (instead of stepping the VFO) |
| Signal history | A CW/PSK31 row's chevron shows its full history |
| Pause new rows | Hover the list; "N new ↓" shows them |

The decode list is always shown: the cursor's row first, then FT8/WSPR messages (newest slot first),
then the other CW/PSK31 signals. FT8 and WSPR need a live radio (RSP1B or Demo): they are off for IQ
files. Slot timing is UTC from the system clock, and the panel warns when the clock is more than 1 s
off. After each slot the strip shows its outcome: "WSPR 14:32 · 2 decodes", "· no decodes", or
"· skipped (audio gap)" when some of the slot's audio was lost. FT8 and WSPR search the whole decode
band, so a HamItUp oscillator a few hundred hertz off (2 ppm at 125 MHz is 250 Hz) still decodes; the
decoded audio frequencies then show the error, which Settings' HamItUp LO corrects. If the passband can't be decoded (narrower than 50 Hz above 300 Hz), the panel says so.

RTTY and auto-detect are disabled for now; their code is kept (`RTTYModem`, `SignalClassifier`, and the
engine's support for both) and covered by the tests.

## Manual hardware checklist
Run through this with an RSP1B attached before a release:
- [ ] Tune: click, type a frequency, scroll a digit, pick a bookmark
- [ ] Gain: change LNA state and IF gain reduction; level responds
- [ ] Overload banner: strong signal shows the banner, "Reduce gain" clears it
- [ ] Unplug the RSP, see the banner, replug, press Retry
- [ ] Change the sample rate while running
- [ ] Quit, then relaunch: no "device busy" error
- [ ] Switch the audio output device while running; audio continues

## Adding a modem
Modems decode the box's 12 kHz real USB audio on the modem thread (`ModemEngine`).
1. Add a case to `ModeID` (`Sources/Modems/Framework/ModemTypes.swift`) with its label, listen filter
   width and lock range (the compiler points to the other switches over modes).
2. Create `Sources/Modems/<Name>/` with either
   - a `StreamingModem` (continuous modes, one decoder per tracked signal): `id` and
     `makeDecoder(frequencyHz:sampleRate:)` returning a `SignalDecoder` (`process(_:)` returns new
     text; `frequencyHz` follows the signal; `submode`; `constellation()` for the bench; `reset()`), or
   - a `SlotModem` (fixed UTC slots): `id`, `slotSeconds` and
     `decode(samples:sampleRate:slotStart:audioBand:)` returning `[SlotDecode]`, run off the modem
     thread on each complete slot.
3. Add one line: the type to `ModemCatalog.streaming` or `ModemCatalog.slot` in the same file, and
   the mode to `ModemControl.offeredModes` (`Sources/SubFloor/App/ModemControl.swift`) for the panel.
4. Add tests in `Tests/ModemsTests` (see `Tests/ModemsTests/Support/ModemTestSignals.swift`).
