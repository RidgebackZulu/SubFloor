# Multi-signal Modems: Performance and Live-band Verification

Verification record for Task 17 of `docs/superpowers/plans/2026-10-20-multisignal-modems.md`, against
spec §8 (CPU), §9 (decode-quality targets) and §9a (live verification) of
`docs/superpowers/specs/2026-10-20-multisignal-modems-design.md`.

The document has two kinds of section:

- **MEASURED (Linux x86 harness, stand-in Accelerate).** Run on 2026-10-20 in the Linux check
  container: Swift 6.2.4, 4-core Intel Xeon @ 2.10 GHz, release build (`-c release -Xswiftc
  -enable-testing`). The harness builds `DSPCore`, `Modems`, `CFT8` and `SubFloorCore` with a
  **pure-Swift stand-in for Accelerate**, whose FFTs and vector routines are slower than vDSP. The figures
  are therefore conservative for the Mac, but they are not Mac figures. The `SubFloor` app target and
  `SDRplayKit` cannot be built there.
- **TO-DO (needs the Mac and the RSP1B).** Not run yet. Nothing in these tables has been measured; fill
  them in on the Mac.

---

## 1. Test suites — MEASURED (Linux x86 harness, stand-in Accelerate)

Branch head `479071f` plus `Tests/ModemsTests/ModemEnginePerformanceTests.swift`, with the working tree
also holding another task's in-progress (uncommitted) changes at the time (among them
`Tests/ModemsTests/ModemSettingsTests.swift`). Full release run: 287 tests in 12 suites, 32.1 s wall.
Re-run on the final commit before signing off.

| Module (test target) | Tests | Result |
|---|---|---|
| `AccelerateShimTests` (harness only: checks the stand-in against direct computation) | 4 | all pass |
| `DSPCoreTests` | 46 | all pass |
| `ModemsTests` | 213 | all pass (28.9 s) |
| `SubFloorCoreTests` | 24 | 23 pass; `unpreservableCorruptFileIsLeftInPlace` fails (see note) |
| `SubFloorTests` (app) | — | not buildable on Linux — **TO-DO on the Mac** |
| `SDRplayKitTests` | — | not buildable on Linux; hardware tests need `SUBFLOOR_HW=1` — **TO-DO on the Mac** |

Note: `unpreservableCorruptFileIsLeftInPlace` fails only because the container runs as root, so the
read-only directory it relies on is writable. It is the known baseline failure and unrelated to the
modems.

The debug build (`swift build --build-tests`) is warning-free, and in it the two performance tests are
skipped with the message "timing test: runs only in an optimised build (swift test -c release)".

### Mac test run — TO-DO

| Command | Result |
|---|---|
| `swift test` (debug, all targets) | 2026-10-20, `507026e`: 399 tests, 6 issues. Seen: `ClockCheckTests.queryTimesOut` (async wrapper's queue started > 1.5 s late under the parallel run; test fixed in `c789515`). The other issues were not in the pasted output: TO-DO, re-run on `c789515` or later |
| `swift test -c release -Xswiftc -enable-testing` (runs the performance tests) | 2026-10-20, `507026e`: 399 tests, 2 issues, both test-timing assumptions fixed in `c789515`: `queryTimesOut` (as above) and `iqOverflowMarksGapWhereLost` (a second, genuine IQ loss on the Mac; the test assumed exactly one). Re-run on `c789515` or later: TO-DO |
| `ModemEnginePerformanceTests` figures with real vDSP (fill in §2's Mac column) | done, see §2 |

---

## 2. Engine performance — MEASURED (Linux x86 harness, stand-in Accelerate)

`Tests/ModemsTests/ModemEnginePerformanceTests.swift` (release builds only; the debug check is
`!_isDebugAssertConfiguration()`, verified to skip in debug and run in release on the harness).

Input for both tests: 60 s of 12 kHz box audio with **30 PSK31 signals**, distinct ~140-character texts,
at 350…3250 Hz (100 Hz grid ±4 Hz, so at least 92 Hz apart), SNR 0…+15 dB each in a shuffled order
(2.5 kHz bandwidth, ruling R7), start times staggered 0.5…11.8 s. The engine is set up as the app's
default (`ModemSettings(mode: .psk31, autoDetect: true)`), fed in the app's 2048-sample blocks with UTC
times (so the slot recorder runs too). Only the feeding is timed.

| Test | Measured (harness) | Mac (real vDSP) | Gate |
|---|---|---|---|
| `thirtyPSKDecodersRealtimeHeadroom`: 60 s through the engine | 1.52–1.71 s, **35–39× real time** (RTF 0.025–0.028) | **0.613 s, 97.8× real time** (RTF 0.0102) | < 6 s (≥ 10×) |
| — decoders running at once | 30 | 30 | ≥ 30 |
| — signals decoded at ≥ 0.9 character accuracy | **30 / 30** (every signal 1.00) | **30 / 30** (every signal 1.00) | ≥ 28 / 30 |
| `thirtyPSKDecodersPlusFT8`: same engine run with four busy FT8 slots decoded concurrently on another thread (as the app's slot queue does) | engine 1.48–1.84 s; total wall **2.0–2.2 s** (≥ 27× real time) | engine **0.586 s, 102× real time**; 30 / 30 PSK31 at 1.00 (total wall not in the pasted output) | total < 6 s |
| — one busy FT8 slot alone (20 signals, −16…+10 dB, 140 Hz apart) | **0.46–0.55 s**, 20 / 20 decoded | TO-DO | < 3 s |
| — FT8 decodes per slot while concurrent | 20, 20, 20, 20 of 20 | TO-DO | ≥ 18 each |

Ranges cover three release runs (the suite on its own twice, and inside the full suite with the other
suites running in parallel). Other speed figures printed by the existing tests in the same run:

| Figure | Harness |
|---|---|
| `ModemEngineTests.parallelDecode` (5 PSK31 + 2 CW, auto-detect, 40 s) | 0.47 s, 85× real time (Mac: 0.194 s, 206×) |
| FT8 slot decode, 8 signals at −15 dB / noise only | 0.35 s / 0.28 s |
| WSPR slot decode, 4 signals at −24 dB / noise only (120 s slot) | 0.12 s / 0.04 s searching 1350–1650 Hz; 0.41–0.45 s / 0.37–0.41 s searching the whole 300–3300 Hz band (since the search follows the decode band, so an up-converter's LO error cannot move signals out of it) |
| Classifier, one call on a 2 s / 16 s capture | 0.30 ms / 2.36 ms |

The FT8 slots of the concurrent test are separate synthetic audio, not the PSK31 band itself; the point
is the CPU of both workloads at once. In the app the slot decode runs on a background queue (another
core), so the modem thread's budget is the engine figure.

---

## 3. Decode quality (spec §9) — MEASURED (Linux x86 harness, stand-in Accelerate)

All synthetic, seeded, 12 kHz, AWGN with SNR in 2.5 kHz (ruling R7). "Pass" means the test's assertion
held in the 2026-10-20 run; where the test prints its figure, the figure is given.

| Mode | Spec target | Test | Measured |
|---|---|---|---|
| PSK31 (BPSK) | −10 dB, ≥ 95 % | `PSK31Tests.bpskMinus10dB` (mean over held-out seeds 1001–1020) | pass (mean ≥ 0.95) |
| PSK31 (BPSK) | +10 dB, 100 % | `PSK31Tests.bpskCleanDecode` (20 held-out seeds, exact including the first character) | pass (100 %, BPSK31 detected) |
| PSK31 (QPSK) | — (extra) | `qpskCleanDecode` +10 dB exact; `invertedSenseQPSKDecodes` mean ≥ 0.95 | pass |
| RTTY 45.45 Bd / 170 Hz | −5 dB, ≥ 95 % | `RTTYTests.minus5dB` (seeds 1–5), `minus5dBHeldOut` (20 held-out seeds), `minus5dBWithTrackerError` (±6 Hz) | pass (means ≥ 0.95) |
| RTTY | — (extra) | `weakToneDecodes` (upper tone −6 dB, 0 dB), `slowSelectiveFadeDecodes` (+5 dB, tone to −20 dB) | pass |
| CW 20 WPM | −8 dB, ≥ 95 % | `CWModemTests.decodesAtMinus8dB` (mean over held-out seeds 1001–1040) | pass (mean ≥ 0.95) |
| CW | — (extra) | 8 / 12 / 35 / 40 WPM at +10 dB, ≥ 0.95 each | pass |
| FT8 | −20 dB, ≥ 80 % | `FT8Tests.minus20dB` (20 trials, gate ≥ 16, no wrong decodes) | **20 / 20, 0 wrong** (also on the Mac) |
| FT8 | — (extra) | six signals at −10 dB in one slot; 0 dB with −10/−15/−20 dB neighbours 60 Hz away | all decoded; reported SNR within 0.6 dB (−18 dB read −17.5 dB) |
| FT8 | no garbage | 30 noise-only slots | 0 decodes |
| WSPR | −28 dB, ≥ 80 % (gate −26 dB) | `WSPRDecoderTests.minus26dBGate` (gate ≥ 16 / 20, no wrong) | **20 / 20, 0 wrong** |
| WSPR | −28 dB stretch | `minus28dBStretch` (not asserted beyond no wrong decodes) | **20 / 20, 0 wrong** — the spec target is met |
| WSPR | — (extra) | strong 0 dB + weak −20 dB 6 Hz apart; reported SNR | both decoded; SNR within 0.3 dB |
| WSPR | no garbage | 20 noise-only slots; Fano on 200 noise frames | 0 decodes; 0 / 200 accepted |
| Parallel decode | 5 PSK31 + 2 CW | `ModemEngineTests.parallelDecode` (+5 / +10 dB) | pass (each ≥ 0.95, no stray text) |
| No garbage | 60 s noise, no characters | `ModemEngineTests.noGarbage` (CW, PSK31, RTTY, auto-detect; with and without a cursor on noise) | pass (0 characters) |
| Classifier | +5 dB, ≥ 90 % | `SignalClassifierTests` confusion matrix, 20 held-out trials per mode, 2 s captures | **CW, BPSK31, QPSK31, RTTY 20 / 20 each** (100 %); 4 s captures, CW / BPSK31 / QPSK31: 10 / 10 each, no CW–PSK confusion |

Fixes recorded in this branch's history that bear on these figures: robust PSK31 acquisition, squelch and
QPSK sense (`7692cb3`); CW speed tracking, low-SNR decode, AFC and held-out sensitivity (`e826b9e`,
`6bfc807`, `cb7450e`); CW trailing-dot and RTTY leading-character artifacts (`6d880d0`, `fa7d107`); busy-band
tracker separation and fading-robust FSK pairing (`ec20acb`, `d67ee73`).

No §9 target fell short on the harness; nothing is flagged.

---

## 4. CPU in the release app (spec §8, plan Task 17 Step 2) — TO-DO (needs the Mac)

Target: **< 30 % of one core for the whole process**, release build, 2 MSPS, FFT 8192, 30 active PSK31
decoders plus FT8.

Procedure:

1. Build the bundle: `scripts/bundle.sh` (release, arm64, `build/SubFloor.app`).
2. Launch `build/SubFloor.app`. Select the **Demo** source at **2 MSPS**, **FFT 8192**.
3. Modem panel: mode **PSK31**, **Auto-detect on**. Place the box on the Demo signals; note how many
   signals are tracked and decoding (the target condition is 30 PSK31 decoders plus FT8 slots; record the
   actual count the Demo source gives).
4. Find the pid (`pgrep SubFloor`) and sample: `top -l 5 -pid <pid> -stats cpu`. Discard the first
   sample (top's first reading is cumulative); record the other four and their mean.
5. Repeat at **10 MSPS** for information only (not gated).

| Date / build (commit) | Rate | FFT | Mode | Signals tracked / decoding | `top` samples 2–5 (% CPU) | Mean | Target | Pass? |
|---|---|---|---|---|---|---|---|---|
| 2026-10-20, `507026e` | 2 MSPS | 8192 | PSK31 + auto, Demo source | TO-DO | 26.4, 65.5, 60.9, 63.1 | **54 %** | < 30 % | **No** (see §4.1 for the per-thread figures and fixes; ≈ 51 % after them) (modem-off baseline and a per-thread profile needed). The machine was under memory pressure (≈ 300 MB free, 11 GB compressed). For scale, on the x86 harness the 2 MSPS modem channel costs ≈ 6 % of a core and the 12 kHz engine ≈ 1 % |
| TO-DO | 10 MSPS | 8192 | PSK31 + auto | TO-DO | TO-DO | TO-DO | info only | — |

Mac model / macOS version: M2 Pro; macOS version TO-DO.

### 4.1 Per-thread CPU on the Mac (Instruments Time Profiler) and the fixes it led to

`top` swung ±10 points between identical runs on this Mac (memory pressure, efficiency vs performance
cores), so the figures below are Instruments Time Profiler totals: real CPU per thread over 10 s, as a
percentage of one core. Demo source, 2 MSPS, FFT 8192, modem PSK31 with auto-detect.

| Thread | Before (`507026e`) | After (`c74a485`) | What changed |
|---|---|---|---|
| Main thread (SwiftUI/AppKit) | 36 % | **15.4 %** | `6f0b606` meter no longer animates for good; `587063a`, `0ed1078` fast-changing values read only by the small views that show them (segmented pickers were re-measured on every update); `d5cc708` window minimum size without measuring the whole window; `7e8a145` everything shown updates together at 5 Hz; `c74a485` slot countdown drawn in a Canvas once a second; `97dfdcf` spectrum presented only when there is something new |
| Worker threads (Demo generator; FT8/WSPR slot decoding) | ≈ 19 % (generator most of it) | 18.6 % (generator ≈ 14 %) | `43e18ce` generator uses phasors instead of per-sample `cos`/`sin` |
| `SubFloor DSP` (spectrum, receiver, 2 MSPS modem channel) | 6–10 % | 10.4 % | — |
| `SubFloor Modem` (all decoders, tracker, classifier) | 3–5 % | 6.2 % | — |
| **Process** | **≈ 70 %** | **≈ 51 %** | |

Against the target (< 30 % for the whole process): **not met on the Demo source (≈ 51 %)**. The Demo
generator only runs for the Demo source, so on the RSP1B the process should be about 35–37 %, still over
the target. Remaining candidates: vectorising the Demo generator, and fusing the full-rate NCO mix with
the first decimation stage (done twice per block, for the receiver and for the modem channel).

---

## 5. Live-band check (spec §9a, plan Task 17 Step 3) — TO-DO (needs the RSP1B)

Setup: RSP1B with the **HamItUp upconverter enabled** in SubFloor. The controller or the user drives the
UI. Tune each frequency, leave it **2–5 minutes**, and record what decoded, with UTC timestamps. Live
results depend on propagation: **an empty band is recorded as "empty band", not as a failure** (the §9
synthetic tests are the hard gate).

Session date, antenna, time of day, band conditions: TO-DO.

### 5.1 Decodes

| Mode | Frequency | Start / end (UTC) | Signals seen in the box | What decoded (examples, with UTC timestamps) | Empty band? | Notes |
|---|---|---|---|---|---|---|
| FT8 | 14.074 MHz USB | TO-DO | TO-DO | TO-DO | TO-DO | TO-DO |
| WSPR | 14.0956 MHz dial | TO-DO | TO-DO | TO-DO | TO-DO | WSPR slots are 2 min: stay ≥ 4 min. The strip shows each slot's outcome ("WSPR 14:32 · 2 decodes", "· no decodes", "· skipped (audio gap)"); decodes far from 1400–1600 Hz audio mean the HamItUp LO setting is off by that much |
| PSK31 | 14.070 MHz | TO-DO | TO-DO | TO-DO | TO-DO | TO-DO |
| CW | 14.030 MHz | TO-DO | TO-DO | TO-DO | TO-DO | TO-DO |
| RTTY | 14.085 MHz | TO-DO | TO-DO | TO-DO | TO-DO | TO-DO |

(Spec §9a alternatives if 20 m is closed: FT8 7.074 MHz USB, WSPR 7.0386 MHz dial, CW 14.000–14.060,
RTTY 14.080–14.090.)

### 5.2 Clock warning

| Check | Expected | Observed |
|---|---|---|
| Clock-offset warning state at startup (NTP check) | warning shown only if the system clock is off by > 1 s; none if NTP is unavailable | TO-DO |
| Measured clock offset (if shown) | — | TO-DO |
| FT8/WSPR time offsets (dt) of live decodes, consistent with the clock state above | — | TO-DO |

### 5.3 UI behaviours

| Behaviour (spec §5) | Expected | Observed (OK / issue) |
|---|---|---|
| Box drag | moves only when dragged by the grab tab; pans in RF, never retunes the hardware; clicking outside the box never moves it | TO-DO |
| Re-center | places the box centre at the centre of the view, clamped to the span; box outside the span shows "Modem box is outside the captured band — Re-center" | TO-DO |
| Cursor lock | click inside the box snaps to the nearest tracked signal (±25 Hz or the mode's lock range), amber cursor with its audio frequency, AFC follows drift; ←/→ nudge to the neighbouring signal | TO-DO |
| Esc unlock | Esc (or clicking the locked cursor/row) unlocks; mode Off also unlocks | TO-DO |
| Narrow / wide audio | locked: the cursor signal through the mode's filter (PSK31 150, RTTY 400, CW 250, FT8 100, WSPR 50 Hz) at its natural pitch; Wide: the whole 300–3300 Hz box; no cursor: wide; no dropouts on lock/unlock | TO-DO |
| Bench | waveform, ±100 Hz micro spectrum and IQ display of the cursor signal; smooth, no flicker | TO-DO |
| Output rows | one row per signal, cursor row pinned on top, rows do not reorder while reading, no garbage on noise | TO-DO |
| Auto-detect | signals labelled with the detected mode; FT8/WSPR-claimed signals labelled so; grab tab reads "AUTO · 3 kHz" | TO-DO |

### 5.4 Outcome

| Item | Result |
|---|---|
| CPU target (§4) met | TO-DO |
| Live decodes per mode (§5.1) | TO-DO |
| UI behaviours as specified (§5.3) | TO-DO |
| Issues found | TO-DO |
