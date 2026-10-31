# Signal ID: design

**Status:** draft for approval, 2026-10-31

## Why

The owner tunes around HF and VHF and wants to know what a signal is without decoding it: "what type of signal is my cursor on?" Agents need the same answer to run requests like "scan 4–7 MHz for digital signals, identify each one's modulation, and log them as bookmarks".

SubFloor already has a narrow classifier inside the decoder. It looks at ±150 Hz of the decoder's audio and knows CW, PSK31, RTTY, FT8 and WSPR. It is switched off, so the decoder never picks a mode by itself.

This job adds a general **Signal ID** that works on any signal on screen, HF or VHF and above. It measures the signal and names it. It does not decode it.

## Goals

- **Point and know.**
  - Rest the mouse on a signal (spectrum or waterfall) for half a second and the hover label gains a line such as
    `RTTY · 45.45 Bd · 170 Hz shift · 91%`.
  - Right-click a signal for an **ID card** showing:
    - the family;
    - the measured parameters;
    - the best matches, each with a confidence;
    - the evidence behind them;
    - buttons **Tune**, **Bookmark** (pre-filled with the name, frequency, mode, bandwidth and the ID in the
      notes) and **Copy**.
  - Inside the passband with a decoder on, right-click still places the decoder cursor, as it does today,
    and also shows the card.
- **Measure, then name.** For any signal it measures:
  - **Extent and shape:** bandwidth (occupied −20 dB and −6 dB) and centre frequency.
  - **Envelope:** steady, keyed (on/off) or voice-like.
  - **Family:** analog AM, SSB (upper or lower), FM or WFM; CW/OOK; 2-FSK or n-FSK; BPSK, QPSK or 8PSK; MFSK;
    OFDM; unmodulated carrier; or noise.
  - **Parameters by family:**
    - **Symbol rate:** for FSK, PSK and MFSK.
    - **FSK:** shift, and tone count and spacing.
    - **PSK:** order.
    - **OFDM:** carrier spacing and occupied width.
    - **FM:** deviation.
    - **CW:** keying speed in WPM.

  Then it matches the measurements and the frequency (band plan) against a table of known modes.
- **Never guess.**
  - A name is shown only when its confidence is at least **0.7**. Below that the line gives the family and
    parameters, for example `2-FSK · 50 Bd · 850 Hz shift`, with a "?" match list in the card.
  - A noise-only or too-weak point says `No signal` or `Too weak to identify (SNR 4 dB)`.
- **Confirm by decoding where SubFloor can.** When a decoder already running in the decoder panel (FT8, WSPR,
  PSK31 or CW, inside the passband) has decoded the same signal in the last minute, the card says "confirmed
  by decode" and the confidence goes to 1. The ID never starts a decoder of its own.
- **Switch the decoder's auto-detect back on.** The decoder panel's **Auto** picks each signal's decoder
  itself, using the existing narrow classifier. Its RTTY rule is made to work properly as an ID (45.45, 50 and
  75 Bd; 170, 425 and 850 Hz). RTTY decoding stays out of scope.
- **Agents.**
  - `get_cursor` gains a `signal` object for each cursor: family, name or null, confidence, parameters and
    alternatives.
    - It is computed live, off the main thread, for the decoder cursor and the VFO.
    - It is computed for the mouse too, but only when the pointer rested on the spectrum within the last
      30 s. An older mouse position gets `null` with a note.
    - A hover result from the last few seconds is reused.
  - New tool `identify_signal {frequency, bandwidth_hz?}`.
  - New tool `identify_signals {from_hz, to_hz, min_snr_db? (default 10), max_signals? (default 40)}`:
    - It finds every signal across the range and identifies each one.
    - **Within the current capture** it doesn't touch the radio.
    - **Wider than one capture** it steps the radio across the range in capture-sized pieces, dwelling long
      enough to fill the ring, and holds the radio lock.
      - Afterwards it restores the starting VFO, mode, bandwidth and HamItUp state, and it stops early if the
        owner retunes.
      - It refuses ("The owner is recording: scan only within the current view, or ask the owner") while any
        recording is running or Auto is on. Retuning would split the owner's IQ file and cut an Auto
        recording.
    - The agent logs the results with `add_bookmark`.
  - The skill and tools reference are updated.

## Modes it names

The parameters below are what the matcher looks for. Frequency hints raise or lower a match's confidence; they
never name a signal on their own.

**HF**

| Name | Family and parameters | Hints |
| --- | --- | --- |
| SSB voice (USB/LSB) | SSB, voice envelope, 2.4–3 kHz | LSB below 10 MHz amateur |
| AM voice/broadcast | AM, carrier plus symmetric sidebands | broadcast bands |
| CW | OOK, 50–200 Hz, 5–50 WPM | CW sub-bands |
| RTTY | 2-FSK, 45.45/50/75 Bd, 170/425/850 Hz | amateur RTTY; 850 Hz for weather/military |
| NAVTEX / SITOR-B | 2-FSK, 100 Bd, 170 Hz | 490, 518 and 4209.5 kHz |
| PSK31 / PSK63 | BPSK/QPSK, 31.25/62.5 Bd | digital sub-bands |
| FT8 / FT4 | 8-GFSK 6.25 Hz / 4-GFSK 20.8 Hz, 15 s / 7.5 s slots | the FT8/FT4 frequencies |
| WSPR | 4-FSK, 1.46 Bd, about 6 Hz | the WSPR frequencies |
| Olivia | MFSK, 4–64 tones, 125–2000 Hz wide | |
| MFSK16 | MFSK, 16 tones, 15.6 Bd | |
| ALE (MIL-STD-188-141) | 8-FSK, 125 Bd, 250 Hz spacing, 750–2500 Hz | |
| STANAG 4285 | 8PSK, 2400 Bd, carrier 1800 Hz | |
| HF fax | FM, 800 Hz shift (1500–2300 Hz), 120 lpm | the fax frequencies |
| DRM | OFDM, 4.5–20 kHz | broadcast bands |
| HFDL | PSK, 1800 Bd | |
| Time signal (WWV/WWVH/CHU) | AM with second ticks | 2.5, 5, 10, 15, 20 and 25 MHz; 3330, 7850 and 14670 kHz |

**VHF and above**

| Name | Family and parameters | Hints |
| --- | --- | --- |
| NFM voice | FM, 8–16 kHz, voice | |
| WFM broadcast | FM, about 200 kHz, 19 kHz pilot | 88–108 MHz |
| AM airband | AM, 8.33/25 kHz | 118–137 MHz |
| APRS / AX.25 | NFM carrying AFSK 1200 Bd (1200/2200 Hz) | 144.39 / 144.8 MHz |
| POCSAG | 2-FSK, 512/1200/2400 Bd, ±4.5 kHz | |
| DMR | 4-FSK, 4800 Bd, ±1.944 kHz, 30 ms TDMA bursts | |
| P25 Phase 1 | C4FM 4-FSK, 4800 Bd, continuous | |
| NXDN | 4-FSK, 2400/4800 Bd, 6.25/12.5 kHz | |
| D-STAR | GMSK, 4800 Bd | |
| YSF (C4FM) | 4-FSK, 4800 Bd, ±2.7 kHz | |
| AIS | GMSK, 9600 Bd | 161.975 / 162.025 MHz |
| ACARS | AM carrying MSK 2400 Bd | 129–137 MHz |
| NOAA APT | FM carrying a 2400 Hz AM subcarrier | 137.1–137.9 MHz |
| DAB | OFDM, 1.536 MHz | 174–240 MHz |

Neighbours that share parameters (DMR, YSF, P25) are told apart by burst structure and deviation. If they
can't be, the card shows the alternatives and the family, never a guessed single name.

## How it works

- **Source.** The ID reads the last **3 s** of raw IQ that SubFloor already keeps for pre-roll, through a
  read-only snapshot of the IQ recorder's ring (at least 5 s and by default 30 s are kept).
  - **Slow signals get a longer read.** When the first pass finds a signal under 50 Hz wide, keying slower
    than 10 WPM, or a candidate that needs timing (WSPR, FT8/FT4 slots, fax lines, time-signal ticks), it
    reads up to **16 s** in a second pass, limited by what the ring holds since the last retune.
  - **Hover shows the first answer, then refines.** The line shows the first result at once, marked
    "measuring…", and updates when the longer pass finishes, within about 1 s of compute.
  - Only samples since the last retune are used; if that is under 1 s, the result is "too soon after
    tuning, try again".
  - Nothing new runs on the DSP thread, and nothing is copied there.
  - With the radio stopped, or on the demo source, it uses whatever is in the ring, or says there is no
    data.
- **Finding the signal.** From the averaged spectrum around the pointed-at frequency, it takes the strongest
  peak within ±(a few pixels' worth of Hz) and grows the signal's extent until the spectrum falls to the
  local noise. `bandwidth_hz` from an agent overrides this.
- **Analysis.**
  - **Channel:** mix the signal to baseband, decimate to about 4× its bandwidth (at least 8 kHz), and filter.
  - **Features:**
    - envelope statistics;
    - instantaneous-frequency histogram and its peaks, giving FSK tones and shift, and FM deviation;
    - spectral lines of |x|² and of the instantaneous frequency's derivative, giving the symbol rate;
    - spectral lines of xⁿ (n = 2, 4, 8), giving PSK order;
    - cyclic-prefix autocorrelation and carrier comb, giving OFDM;
    - sideband asymmetry, giving SSB versus AM;
    - pilot and subcarrier tones, for WFM, APT and AFSK;
    - burst timing, for TDMA and slot modes.
  - **Then:** family rules, then the named-mode table.
- **Where it runs.** Off the main thread, cancellable when the pointer moves on. Target: ≤ 150 ms per signal
  on Apple Silicon (release build). Hover results are cached per frequency for a few seconds.
- **Code.**
  - A new `SignalID` module (pure, no AppKit), alongside `Modems`.
  - The ring snapshot goes in `Recording`.
  - The UI goes in the spectrum overlay.
  - The tools are added to the MCP registry.

## Non-goals

- Decoding any of the new modes.
- Labelling every signal on screen continuously (the owner chose point-and-ask).
- Machine-learning classifiers.
- ADS-B, LoRa and other signals wider than the capture or needing faster sampling.
- RTTY decoding.

## Anti-goals

- **A confident wrong name.** A signal named at ≥ 0.7 that is wrong is worse than "2-FSK · 50 Bd". The tests
  measure the false-name rate.
- **Hover that stutters the waterfall or the audio.**
- **An agent scan that leaves the radio somewhere else.**

## Testing

- **Synthetic signals.** A generator in the tests makes each family and named mode with exact parameters,
  at SNRs of 20, 10, 6 and 3 dB, with frequency offset and fading.
- **SNR** means signal power over noise power within the signal's own occupied bandwidth, both in the test
  generator and in the "Too weak" line.
- **Targets on synthetic signals:**
  - **At ≥ 10 dB SNR:** family right ≥ 95%; symbol rate within 1%; shift within 3%; bandwidth within 10%;
    named mode right ≥ 90% where the parameters are distinctive.
  - **At 3 dB:** "unknown" or the family is fine, but a wrong name at ≥ 0.7 must happen in ≤ 2% of cases.
- **Real recordings.**
  - SubFloor's own audio recordings (`~/Music/SubFloor`: 11.175 MHz USB voice, FT8 at 14.074 and others) are
    used through a second entry point: SSB-demodulated audio turned back into its analytic (complex) signal
    is the passband's IQ. This covers the narrowband modes (voice, FT8, CW, PSK, RTTY), but it can't test AM
    against SSB.
  - The one IQ WAV in the folder is used as it is.
  - The owner may add more later.
  - VHF modes are tested on synthetic signals only, a known gap that the report says.
- The existing decoder classifier's tests keep passing, and the RTTY ID gets tests for each rate and shift.

## Calls made in review (the designer's, open to change)

- **Decode confirmation:** it only reads the decoders already running.
- **Slow signals:** they get a second, longer read of up to 16 s.
- **A wide scan defers to the owner:** it refuses while the owner is recording or has Auto on, and restores
  the starting tuning afterwards.
- **Audio fixtures:** the real-recording tests use SubFloor's audio, turned back into IQ.
- **SNR:** it is measured within the signal's own bandwidth.
- **`get_cursor`:** it identifies live, and skips a mouse position older than 30 s.

## Calls left to the builder

- Exact thresholds (tuned on seeds kept apart from the asserting tests, as the decoder classifier was).
- Card layout within the description above.
- How the IQ ring snapshot converts from int16, int24 or float32.
