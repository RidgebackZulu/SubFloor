# Vendored: ft8_lib

- **Upstream:** https://github.com/kgoba/ft8_lib
- **Pinned commit:** `9fec6ca39886edbf96f4f5e71edc76da5074e871` (2025-08-23, "non-standard callsigns; special CQ;
  field type annotation (#47)")
- **Licence:** MIT, Copyright (c) 2018 Kārlis Goba — `LICENSE` (upstream's file, unchanged).
- **Vendored on:** 2026-10-20, for SubFloor's FT8 slot decoder (`Sources/Modems/FT8`).

## What is here

| Path | From upstream | Notes |
|---|---|---|
| `ft8/*.c`, `ft8/*.h` | all of `ft8/` | packing, CRC, LDPC, encoder, candidate search and soft-bit extraction |
| `common/monitor.c`, `common/monitor.h`, `common/common.h` | `common/` | the waterfall ("monitor") that the decoder works on |
| `fft/kiss_fft.c`, `fft/kiss_fft.h`, `fft/kiss_fftr.c`, `fft/kiss_fftr.h`, `fft/_kiss_fft_guts.h` | all of `fft/` | KISS FFT, which `common/monitor.c` needs |
| `LICENSE` | `LICENSE` | ft8_lib's MIT licence |

Every vendored file is byte-for-byte identical to the pinned commit. **No vendored source is modified.**

Excluded: `common/audio.c`/`audio.h` (PortAudio input) and `common/wave.c`/`wave.h` (WAV file I/O), which
SubFloor does not need, and upstream's `demo/`, `test/`, `utils/` and `ft4_ft8_public/` (the last holds
WSJT-X's Fortran reference files, which are not needed and not vendored).

## KISS FFT (bundled inside ft8_lib)

ft8_lib's `fft/` directory is a portion of KISS FFT by Mark Borgerding, https://github.com/mborgerding/kissfft,
licensed **BSD-3-Clause** (each file's header: "Copyright (c) 2003-2010, Mark Borgerding. All rights reserved.
SPDX-License-Identifier: BSD-3-Clause. See COPYING file for more information."). ft8_lib does not ship KISS FFT's
`COPYING`, so `LICENSE.kissfft` reproduces it: KISS FFT's `COPYING` and its `LICENSES/BSD-3-Clause` text (fetched
from kissfft's master branch, commit `2a1f1337160e6e8dbc6182202d0bd7f624002197`, on 2026-10-20), with the BSD
template's copyright line filled in from the file headers. The BSD-3-Clause terms require the copyright notice and
licence to accompany binary distributions: the app's acknowledgements must include both `LICENSE` and
`LICENSE.kissfft`.

Neither licence is GPL. No WSJT-X code is vendored.

## SubFloor's own files in this target

- `include/cft8.h`, `include/module.modulemap`: the module's public interface. ft8_lib's headers include each
  other by root-relative paths (`<ft8/decode.h>`) that a Swift client cannot resolve, so Swift sees only
  `cft8.h`.
- `cft8.c`: the slot analysis and decode steps of upstream's `demo/decode_ft8.c` (monitor → candidates → LDPC →
  CRC → unpack, with its time and frequency oversampling of 2) and the packing of `demo/gen_ft8.c`, plus a soft-bit
  entry point for SubFloor's own demodulator. No global state (upstream's demo keeps a global callsign hash table;
  SubFloor passes no hash table, so hashed callsigns read `<...>`), so it is reentrant.

## Build settings (both `Package.swift` files)

```swift
.target(name: "CFT8", path: "Sources/CFT8", cSettings: [
    .headerSearchPath("."),                         // ft8_lib's root-relative includes
    .define("LOG_PRINTF(...)", to: "((void)0)"),    // silence common/monitor.c's stderr logging
    .unsafeFlags(["-O2"]),
])
```

The plan specified only `-O2`. The other two settings replace source edits: without the header search path
`common/monitor.c` does not compile, and without the `LOG_PRINTF` definition `monitor_init` prints three lines to
stderr on every slot (`ft8/debug.h` uses `LOG_PRINTF` when it is defined).

## Warnings

With SwiftPM's default flags (and `-O2`) the target compiles with **no warnings** (checked with clang 17 in the
Linux check harness; Apple clang uses the same defaults). With `-Wall -Wextra` upstream code shows four, all
harmless and left alone:

- `ft8/decode.c`: unused `db_power_sum` table and unused static function `ft8_decode_multi_symbols`;
- `ft8/message.c`: unused locals `i3` (in `ftx_message_decode_nonstd`) and `n58_backup` (in `unpack58`).

## Subtraction

This ft8_lib version has no signal subtraction: `monitor_resynth` in `common/monitor.c` is an unfinished
experiment behind `WATERFALL_USE_PHASE` (it ignores the candidate's time offset and references an undefined
`candidate_t`). SubFloor therefore decodes each FT8 slot in a single pass, which the plan accepts.

## Updating

Clone upstream at the new commit, copy the files in the table over these, keep `LICENSE`, re-check
`LICENSE.kissfft` against KISS FFT's `COPYING`, update the commit above, and run `swift test --filter FT8Tests`.
