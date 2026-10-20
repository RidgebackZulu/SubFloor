# SubFloor

A fast, native macOS (Apple Silicon) receiver for the SDRplay RSP1B: Metal spectrum + waterfall,
AM/NFM/WFM/USB/LSB/CW audio, HamItUp upconverter mode, bookmarks, and a multi-signal modem panel that
decodes every CW, PSK31, RTTY, FT8 and WSPR signal inside a 3 kHz box at once.

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
| HamItUp | Top-bar toggle or ⌘U (LO set in Settings, default 125 MHz) |

## Modem panel
Pick a mode (CW, PSK31, RTTY, FT8, WSPR) in the panel under the spectrum. A green 3 kHz box appears on
the spectrum: it covers RF dial + 300 … 3300 Hz, and each signal's audio frequency is its RF minus the
dial (the box's dial frequency is shown in the panel, "USB"). Every signal in the box gets a row.

| Action | How |
| --- | --- |
| Move the box | Drag its grab tab on the top edge ("≡ PSK31 · 3 kHz"). It never retunes the radio; clicking outside the box still tunes the VFO |
| Re-center the box | "⌖ Re-center box": the middle of the current view, kept inside the captured span |
| Analyse a signal | Click it inside the box: the amber cursor snaps to the nearest tracked signal and follows it; the bench shows its waveform, ±100 Hz spectrum and IQ |
| Unlock the cursor | Esc, click the cursor again, or click its (amber) row |
| Next / previous signal | ← / → while a mode is on (instead of stepping the VFO) |
| Lock on a row's signal | Click the row; its chevron shows the full history |
| Audio | Narrow: the cursor's signal through its mode's filter (wide box audio while no cursor is locked) · Wide: the whole box |
| Auto-detect | Classifies every signal and decodes it in its own mode, FT8/WSPR on every slot; the picked mode is the cursor's fallback |
| Pause new rows | Hover the list; "N new ↓" shows them |

FT8 and WSPR need a live radio (RSP1B or Demo): they are off for IQ files. Slot timing is UTC from the
system clock, and the panel warns when the clock is more than 1 s off. If a retune leaves the box outside
the captured span, decoding stops until the box is re-centered or the radio is tuned back.

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
Modems decode the box's 12 kHz real USB audio on the modem thread (`ModemEngine`); the panel picks up
new modes by itself.
1. Add a case to `ModeID` (`Sources/Modems/Framework/ModemTypes.swift`) with its label, listen filter
   width and lock range (the compiler points to the other switches over modes).
2. Create `Sources/Modems/<Name>/` with either
   - a `StreamingModem` (continuous modes, one decoder per tracked signal): `id` and
     `makeDecoder(frequencyHz:sampleRate:)` returning a `SignalDecoder` (`process(_:)` returns new
     text; `frequencyHz` follows the signal; `submode`; `constellation()` for the bench; `reset()`), or
   - a `SlotModem` (fixed UTC slots): `id`, `slotSeconds` and
     `decode(samples:sampleRate:slotStart:audioBand:)` returning `[SlotDecode]`, run off the modem
     thread on each complete slot.
3. Add one line: the type to `ModemCatalog.streaming` or `ModemCatalog.slot` in the same file.
4. Add tests in `Tests/ModemsTests` (see `Tests/ModemsTests/Support/ModemTestSignals.swift`).
