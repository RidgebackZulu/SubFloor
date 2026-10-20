# SubFloor — Design Spec

Date: 2026-10-19
Status: Approved in brainstorming, pending written-spec review

## 1. Purpose

SubFloor is a native macOS (Apple Silicon) SDR receiver application for the SDRplay RSP1B,
built on the SDRplay API 3.15 (`/usr/local/lib/libsdrplay_api.dylib`, headers in
`/usr/local/include`). It provides deep spectral investigation with a fast GPU spectrum and
waterfall, AM/FM/SSB/CW audio, a modular modem framework, HamItUp upconverter support, and
frequency/mode bookmarks.

## 2. Platform & stack

- macOS 26+, arm64 only. Xcode 26.2, Swift 6.2 (strict concurrency).
- SwiftUI app shell; Metal (`MTKView`) for spectrum/waterfall.
- Accelerate/vDSP for FFT and DSP primitives.
- AVAudioEngine (`AVAudioSourceNode`) for audio output.
- SDRplay API accessed via a C module map (system library target) linking `sdrplay_api`.
- Project structure: a single Swift Package (`Package.swift`), with library targets plus an
  executable target `SubFloor`. Xcode can open `Package.swift` directly for development.
  `scripts/bundle.sh` runs a release build and wraps it into `build/SubFloor.app`, with an Info.plist,
  and an ad-hoc codesign. No third-party generator is needed.
- Metal shaders live in a `.metal` file that is bundled as a SwiftPM resource and compiled at runtime with
  `device.makeLibrary(source:)`. This avoids relying on SwiftPM's metallib handling.

## 3. Phase 1 scope

In: device control, spectrum + waterfall, zoom/pan, VFO, AM/NFM/WFM/USB/LSB/CW demod, audio,
gain/AGC/squelch, sample rate/decimation/IF controls, HamItUp mode, bookmarks (with on-spectrum
flags), quick-tune, synthetic + IQ-file sources, modem framework, CW decoder modem.

Out (later phases): RTTY, PSK31, APRS, FT8 (likely external bridge), IQ/audio recording,
other RSP models, runtime-loaded plugins.

## 4. Architecture

Modules (SwiftPM targets):

| Module | Responsibility | Depends on |
|---|---|---|
| `CSDRplay` | System-library module map for `sdrplay_api.h` | libsdrplay_api |
| `SDRplayKit` | Swift wrapper: device discovery, open/select/init/uninit/release, stream callbacks, update params (freq, gain, sample rate, decimation, IF, bias-T, notches), event callback | CSDRplay, DSPCore (for `IQSource`) |
| `DSPCore` | Pure Swift DSP: SPSC ring buffer, FFT + windows, NCO/mixer, FIR design + decimating filters, AGC, demodulators, `IQSource` protocol, synthetic source, IQ file source | Accelerate |
| `Modems` | `Modem` protocol, `ModemRegistry`, CW decoder | DSPCore, SwiftUI |
| `SubFloorApp` (app) | `AppModel`, frequency mapping, bookmarks store, Metal renderer, SwiftUI views, audio output | all |

### 4.1 Data flow

```
IQSource (SDRplay | Synthetic | File)
   │ complex Float32 interleaved, via SPSC ring
   ▼
DSP queue (one serial, high-QoS thread)
   ├─ SpectrumPipeline: window → vDSP FFT (1k–64k) → |X|² → dB → averaging/peak hold
   │      → triple-buffered MTLBuffer → Metal renderer
   └─ Receiver: NCO shift by VFO offset → decimating channel filter → Demod
          → audio resampler to 48 kHz → audio SPSC ring → AVAudioSourceNode
          └─ ModemHost: feeds demod audio (or channel IQ) to the active Modem
```

### 4.2 Threading

- SDRplay stream callback thread: converts int16 I/Q to Float32, writes to IQ ring. No allocation, no locks.
- DSP thread: reads the IQ ring in fixed blocks, runs spectrum + receiver.
- Audio render thread: reads the audio ring; counts underruns.
- Main/UI: `@Observable AppModel`; parameter changes are posted to the DSP thread via a lock-free
  command queue (or atomic snapshot) and to the device actor.
- Metal draws at display refresh (up to 120 Hz) from the latest completed FFT buffer.

### 4.3 Frequency model

- `hardwareCenterHz`: what the RSP is tuned to.
- `upconverter: { enabled: Bool, loHz: Double = 125_000_000 }`.
- `displayFreq = hardwareFreq − loHz` when the upconverter is enabled, otherwise equal to it. All UI shows display frequencies.
- `vfoHz` (display): the demodulated frequency, which must lie within the captured span.
- **Panning and zooming never retune the radio.** The view state (`viewCenterHz`, `viewSpanHz`) is only a GPU uniform.
- The radio retunes only when (a) the user types or quick-tunes a frequency, (b) a bookmark is selected,
  or (c) the VFO is dragged or stepped beyond ~45% of the sample rate from center. In that case the center
  moves so the VFO sits at the new center (with a small offset to avoid DC).
- `FrequencyMapper` is a pure struct, unit-tested.

## 5. Device (RSP1B)

- Detected with `hwVer == SDRPLAY_RSP1B_ID (6)`. It uses `rsp1aTunerParams` / `rsp1aParams`.
- Frequency range: 1 kHz – 2 GHz.
- Sample rate: 2–10 MSPS (fsHz). There is also low-IF mode for narrower rates; decimation is 1/2/4/8/16/32.
- IF mode: Zero-IF by default. Low-IF is required for the sub-2 MSPS combos the API supports.
- Gain: LNA state, limited per band to the RSP1A/1B table, and IF gain reduction 20–59 dB.
  AGC can be off, 5 Hz, 50 Hz or 100 Hz.
- Extras: bias-T, broadcast notch, DAB notch, DC offset and IQ correction (on by default), PPM correction.
- Events: `PowerOverloadChange` shows a banner and is acknowledged with `Update_Ctrl_OverloadMsgAck`. `DeviceRemoved` stops the stream and shows a banner.
- API lifecycle runs inside `SDRplayDevice` (an actor). `Open`, `LockDeviceApi`, `GetDevices`, `SelectDevice`,
  `UnlockDeviceApi`, `Init`; teardown is `Uninit`, `ReleaseDevice`, `Close`. All API errors are mapped to
  `SDRplayError` with `sdrplay_api_GetErrorString` text.
- Invalid parameter combinations are rejected in Swift before they reach the API.

## 6. DSP & demod

- **Windowing:** Blackman-Harris (default), Hann, Flat-top. FFT size is user-selectable as a power of two from 1024 to 65536.
- **Averaging:** exponential with alpha set by the user. Peak hold can be toggled and reset.
- **Channelizer:** NCO mix, then multi-stage decimating FIR (windowed-sinc design) down to about 48–250 kHz depending on mode,
  then the final audio filter and resampling to 48 kHz.
- **Demods:** each conforms to `Demodulator { func process(_ iq: UnsafeBufferPointer<DSPComplex>, into audio: inout [Float]) }`.

| Mode | Default BW | Step | Method |
|---|---|---|---|
| AM | 8 kHz | 5 kHz | envelope, DC block |
| NFM | 12.5 kHz | 12.5 kHz | quadrature discriminator, de-emphasis off |
| WFM | 180 kHz | 100 kHz | discriminator at 250 kHz, 75 µs de-emphasis, mono |
| USB / LSB | 2.7 kHz | 100 Hz | complex filter selecting sideband, take real |
| CW | 500 Hz | 10 Hz | narrow filter offset by BFO pitch (default 700 Hz) |

- **AGC:** attack/decay with Fast, Medium, Slow and Off presets.
- **Squelch:** power-based, with hysteresis. **Volume:** linear gain plus a soft limiter.

## 7. Spectrum & waterfall (Metal)

- One `MTKView` holds two passes. The spectrum pass draws a line strip plus fill and peak hold.
  The waterfall pass draws a fragment-shaded quad that samples a ring texture
  (`R16Float` or `R32Float`, width = FFT size, height = 1024 rows). Each frame writes one row, and the shader offsets by the head index.
- The colormap is a 256×1 LUT texture: Turbo (default), Viridis or Grayscale.
- Zoom and pan are uniforms (`viewStartBin`, `viewBinCount`) and the CPU does no resampling. When many bins fall into one pixel, the shader
  takes the max over the bins in that pixel (for the spectrum, via a precomputed per-pixel max buffer in a compute pass).
- Overlays drawn in SwiftUI on top of the `MTKView`: frequency ruler, dB grid, VFO passband (draggable edges),
  hover crosshair readout, bookmark flags, and the minimap of the captured span.
- Input:
  - click sets the VFO
  - pinch or ⌥-scroll zooms around the cursor
  - two-finger scroll or drag on empty space pans
  - double-click resets the view
  - dragging the passband edges sets the bandwidth
- dB range and offset sliders sit on the right edge. Waterfall speed is set in rows per second.

## 8. UI

- **Window layout:**
  - **Top bar:** device status chip, Run/Stop, big frequency readout (scroll a digit to step it, click to type), mode menu, BW,
    HamItUp toggle, bookmark-star.
  - **Left sidebar:** Radio (sample rate, decimation, IF mode, LNA, IF gain, AGC, bias-T, notches),
    Audio (volume, squelch, AGC speed, CW pitch), Bookmarks (show-on-spectrum toggle, search, groups, list).
  - **Center:** spectrum above, waterfall below, with a resizable split.
  - **Bottom:** a collapsible modem panel with a modem picker and the active modem's output view.
  - **Status bar:** sample rate, FFT size, CPU %, audio underruns, overload indicator.
- **Frequency input:** the parser accepts `14.074` (MHz is assumed when there's a decimal point and the value is under 3000), `7074k`, `144.39m`,
  `125000000`, `1.2g`.
- **Quick-tune (⌘L or `/`):** a popover that takes a frequency or a fuzzy bookmark name.
- **Keys:**
  - ←/→ steps the VFO by the mode step (⇧ for 10×)
  - [ / ] cycles the mode
  - ⌘D adds a bookmark
  - Space toggles Run
  - ⌘B toggles bookmark flags
- **Appearance:** dark by default (`preferredColorScheme(.dark)`, with a Settings option for System/Light). SF Mono digits,
  accent color for the VFO, sidebar materials.

## 9. Bookmarks

```swift
struct Bookmark: Codable, Identifiable, Hashable {
  var id: UUID
  var name: String
  var frequencyHz: Double      // display frequency
  var mode: DemodMode
  var bandwidthHz: Double
  var upconverter: Bool        // requires HamItUp
  var group: String?
  var colorHex: String?
}
```

- Stored as JSON at `~/Library/Application Support/SubFloor/bookmarks.json`, written atomically. Import and export use the same format.
- Selecting a bookmark sets the upconverter state, mode, bandwidth and frequency, then retunes the hardware.
- With "Show on spectrum" on, bookmarks in the view range appear as flags on the ruler, in their color or the group color.
  Clicking a flag tunes to it.
- A small default set of bookmarks is seeded on first launch, e.g. WWV 10 MHz, 20m FT8 14.074 USB, 2m APRS 144.390 NFM,
  FM broadcast, and one HamItUp HF example.

## 10. Modem framework

```swift
public protocol Modem: AnyObject {
  static var info: ModemInfo { get }          // id, name, input kind (.audio / .iq), preferred demod mode + bw
  init()
  func reset()
  func process(audio: UnsafeBufferPointer<Float>, sampleRate: Double)   // called on DSP thread
  func process(iq: UnsafeBufferPointer<DSPComplex>, sampleRate: Double) // default no-op
  @MainActor func makeOutputView() -> AnyView
}
```

- `ModemRegistry.all: [any Modem.Type]` is the single registration point.
- `ModemHost` owns the active modem. It forwards buffers on the DSP thread. Modems publish their output through their own
  `@Observable` model, updated on the main thread at a throttled rate.
- **Adding a modem:** create `Sources/Modems/<Name>/`, conform to `Modem`, and append it to `ModemRegistry.all`.
- **CW decoder (phase 1):** Goertzel or envelope detection at the CW pitch, an adaptive threshold, automatic WPM estimation from dot length,
  timing classification (dit/dah/element/char/word gap), and a Morse table. Output view: a scrolling monospaced text pane with WPM, signal
  level meter and a clear button.

## 11. Errors

- If the API service is unreachable, a device is busy or no device is present, the app falls back to the synthetic source with a
  "No RSP — demo signal" chip, and shows a banner with Retry.
- Overload and device-removed events are shown as banners, as described above.
- Bookmark file corruption: the bad file is moved to `bookmarks.corrupt.json`, the app starts with defaults, and a banner is shown.
- No crashes on recoverable errors. `fatalError` is used only for programmer errors.

## 12. Performance targets

- Spectrum and waterfall run at display refresh (up to 120 Hz) with FFT sizes up to 64k.
- CPU use stays under 15% of one P-core at 2 MSPS with demod active.
- Hot paths make no heap allocations and take no locks; threads communicate through SPSC rings.
- Audio latency target is about 50 ms, and underruns are counted.

## 13. Testing

- Unit tests (Swift Testing):
  - an FFT bin lands at the expected frequency
  - FIR response
  - ring buffer correctness under concurrency
  - each demod recovers a tone from synthetic AM/NFM/WFM/USB/LSB/CW
  - CW decoder decodes generated Morse at 15/25 WPM
  - `FrequencyMapper` (upconverter, retune rule)
  - frequency text parser
  - bookmark codec round-trip and corrupt-file handling
- Manual hardware smoke test with the RSP1B: enumerate, stream, tune, gain, overload, unplug.
- UI check: run the app with the synthetic source and exercise zoom, pan, click-tune and bookmarks.
