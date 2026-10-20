# SubFloor

A fast, native macOS (Apple Silicon) receiver for the SDRplay RSP1B: Metal spectrum + waterfall,
AM/NFM/WFM/USB/LSB/CW audio, HamItUp upconverter mode, bookmarks, and plug-in modems (CW decoder included).

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
| Step VFO | ← / → (⇧ ×10) |
| Mode | Top bar, or `[` / `]` |
| Zoom / pan | Pinch or ⌥-scroll / two-finger scroll or drag — never retunes the radio |
| Bandwidth | Drag the passband edges |
| Bookmarks | ⌘D add · ⌘B show on spectrum · sidebar list |
| HamItUp | Top-bar toggle or ⌘U (LO set in Settings, default 125 MHz) |

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
1. Create `Sources/Modems/<Name>/<Name>Modem.swift` with a class conforming to `Modem`
   (`info`, `process(audio:context:)` or `process(iq:context:)`, `makeOutputView()`).
2. Append `<Name>Modem.self` to `ModemRegistry.all` in `Sources/Modems/Modem.swift`.
3. Add tests in `Tests/ModemsTests`.
