# Signal ID on real signals: design

**Status:** draft for approval, 2026-11-01

Builds on `2026-10-31-signal-id-design.md`, which stays in force except where this document changes it.

## Why

The owner uses Signal ID on the air and finds SSB voice and CW good, but digital modes failing. They want it "more robust and reliable", and say RTTY/FSK signals are common and they want to ID them. This comes before the noise-floor and C/N markers, which wait until it's done.

The first build reached 97% on signals its own tests generate: clean, one at a time, with no neighbours. Two IQ recordings the owner made on 2026-11-01 show what real bands do to it:

| Recording | What is really there | What Signal ID said |
| --- | --- | --- |
| `SubFloor_20261101_181844Z_14024000Hz_IQ.wav` (1 MS/s, 41 s) | About 6+ FT8 traces, 14.0731–14.0755 MHz | `Unknown · 2.9 kHz` on every trace: the group lumped together |
| Same | FT4, 14.080–14.0816 MHz | Usually `Unknown · 773 kHz` or `No signal`; on 2 of 3 traces `FT8 / FT4 · 100%`, once only when given a width |
| Same | Empty spectrum | `Unknown · 773 kHz` or `781 kHz`, not `No signal` |
| `SubFloor_20261101_184142Z_11733100Hz_IQ.wav` (1 MS/s, 24 s) | 2-FSK, tones at 11.68780 and 11.68865 MHz | `Unknown · 4.7 kHz`, merged with a stronger signal near 11.6859 MHz; an agent-style `bandwidth_hz` was ignored |

**What was measured by hand on those recordings, for the record:**
- **FT4:** one trace measured 4 tones, 20.8 Bd, 20.8 Hz spacing. Transmissions last about 5 s and start every 7.5 s on UTC boundaries, on FT4's usual 20 m frequency.
- **The FSK:**
  - The frequency histogram has two clean humps about 854 Hz apart.
  - The two tones' power has a correlation of about −0.5: they take turns.
  - Tone runs cluster near 13, 27 and 40 ms, which is 75 Bd. Noise adds many shorter runs, so the speed is less certain than the shift.
- **An interference comb:** steady lines about every 19.3 kHz across at least 13.69–14.35 MHz, many doubled about 1 kHz apart. This pattern usually comes from something local, such as a switching power supply. It is probably part of why empty spectrum lumps.
- **Level jumps:** the 14 MHz recording has sudden level changes across the whole band.
- **Frequency error:** the FT8 group sits at least 1.1 kHz below where FT8 belongs, probably the HamItUp's oscillator (not proven).

**The root causes:**
1. It works out what the signal is from one averaged spectrum, which merges everything near the point and can spread across a whole capture.
2. It then grows the extent again while measuring, so an isolated signal gets merged back in.
3. It has no direct way to see that two lines are one FSK signal, or that a line is one station in a slot.
4. Simply filtering the signal first is not enough: on a tried filter-then-measure, the existing measurer still said `Unknown`, with a nonsense SNR of about 97 dB, because the filter removed its noise reference.

## Goals

- **FT8, FT4 and RTTY/FSK work on real signals.** These are the owner's priorities. Named separately, with their parameters.
- **SSB voice and CW don't get worse.** The owner finds them good.
- **Honest answers.**
  - Empty spectrum says `No signal`.
  - A real signal with no name gets its family and numbers.
  - Answers like `Unknown · 773 kHz` no longer happen.
- **Real signals are the score.** Accuracy reported from now on comes from real recordings, per mode. A mode with no real recording says so.

## What the owner sees

The hover line and card work as they do today, with these changes.

**One signal under the pointer:**
- `FT8 · 6.25 Bd · 8 tones`
- `FT4 · 20.8 Bd · 4 tones`
- `RTTY · 45.45 Bd · 170 Hz shift`
- `2-FSK · 75 Bd · 850 Hz shift`, when it's FSK but not shown to be RTTY

**Several signals under the pointer.** At the owner's usual zoom one screen pixel covers about 345 Hz, so one point on an FT8 group covers several stations. The answer describes what's there:
- `FT8 · 9 signals · 14.0731–14.0755 MHz`
- `Several signals: FT8 ×6, unknown ×2`

The card lists them, each with its frequency, name and a Tune button.

"Under the pointer" means the traces inside the point's radius. If they belong to a connected group of one mode, the answer describes the whole group: the span in the first example is wider than the radius.

**Empty spectrum:** `No signal`.

**A comb line:** `Interference comb · 19.3 kHz spacing`.

**The card's evidence** gains lines such as "transmissions start on 15 s UTC boundaries", "the two tones take turns", and "decoded: CQ K1ABC FN42".

## How it works

**1. Look around the point, over time.** Build a picture of frequency against time (a spectrogram) of the neighbourhood of the point, from the IQ ring, channelised first so the capture's rate doesn't matter. Normalise each moment by its own noise level, so level jumps don't read as signals.

**2. Find traces.** Pick out each narrow line and its on/off times. Wider occupied areas (voice, AM, OFDM, FM) stay as areas with edges.

**3. Bound the signal.** The noise reference is local, taken from the neighbourhood, and comb lines don't count as signal or as noise.
- Nothing in the point's radius means no signal there. It never searches further out.
- The radius comes from the view: a few pixels' worth of Hz at the current zoom. Agents can give it, and otherwise get a default suited to narrow signals.
- An extent only grows while the spectrum stays above the local noise and the shape stays one signal. A very wide answer needs positive evidence, such as flat-topped occupancy with sharp edges (WFM, DAB).
- An agent's `bandwidth_hz` is honoured and not grown.

**4. Group traces into signals.**
- Lines whose power takes turns are one FSK signal, however far apart within a plausible shift. Lines that ignore each other are separate.
- Close tones that hop, as in FT8, are one signal.
- Two carriers or stations never become one because they're adjacent.

**5. Measure each signal on its own.**
- FSK gets a direct measurement from its grouped tones: tone count, spacing or shift, and speed from tone runs and keying lines.
- SNR comes from a real noise reference, so whatever isolates the signal must leave noise to measure against.
- Strong neighbours are removed before measuring.
- PSK, OFDM and analog keep their existing features, fed the isolated signal.

**6. Look at the wider picture.**
- **Slots:** transmissions starting on UTC 15 s or 7.5 s boundaries, and lasting about 12.6 s or 4.5 s, are strong evidence for FT8 or FT4. This allows for the Mac's clock being off by up to about 2 s.
  - The IQ ring's snapshot gains the UTC time of its samples, set when they arrive, so timing stays right with the radio stopped. The demo source and files with no known time get no slot evidence.
  - Because 2 s is a large share of a 7.5 s slot, timing alone never names a mode. The tone numbers must already fit.
- **FT8 and FT4 become two table rows,** told apart by their numbers.
- **The comb:** many narrow, steady, evenly spaced lines across the capture are labelled as interference. A line that's keyed or modulated is never labelled comb, even if it lands on the grid.
  - It runs on the app's averaged spectrum of the whole capture, kept up to date no more than once every few seconds, not on the neighbourhood from step 1.
  - It needs at least 8 lines. A capture too narrow to show 8 lines never labels a comb, and those lines get the ordinary answer. Agents without an app spectrum work it out from the ring's newest read.

**7. Try a real decode where SubFloor can.**
- **FT8:** the existing decoder, on the latest complete slot in the ring. A checked message is near-certain proof. This changes the earlier rule that Signal ID never starts a decoder: this runs privately on ring samples and doesn't touch the decoder panel or decode history.
- **PSK31 and RTTY:** the existing decoders. Readable text counts as evidence, for the rates and shifts they follow. Text that isn't readable counts for nothing; it isn't evidence against.
- **No trial decode:** WSPR (its two-minute slot doesn't fit the ring), so it keeps reading only the running decoder, and FT4 (no full decoder yet).
- **When:** for the card and for agents, not for hover. Hover is unchanged until the card opens. A scan decodes a group's slot once, not once per signal.

**8. Name it.** The mode table and the 0.7 rule stay.
- **The name "RTTY"** needs either the amateur RTTY segments or readable text from the trial decode. Otherwise it stays `2-FSK` with its numbers.
- **Frequency hints** allow for about 2 kHz of tuning error.

**Whose request goes first.** Trial decodes and longer reads take seconds, so a first-come queue would make hover wait. The owner's hover and card now go ahead of queued agent and background work, and a newer hover replaces an older one still queued. There's still only one identification at a time, so the memory limits hold. A running low-priority job stops at its next cancellation check when the owner asks for something.

**Time and timing:**
- A silent moment isn't an empty frequency. FT8 stations often transmit only every other slot, so before saying `No signal` it looks back up to 16 s. The line says it's measuring while it does.
- Hover's first answer stays quick; the existing "measuring…" refinement carries the rest.
- A trial decode can use as much of the ring as a complete slot needs, up to about 28 s for FT8. If the ring holds less, it goes without the decode.
- Everything still runs one at a time on the identification executor, off the main thread, cancellable, within the memory limits of the first build.

**Agents:**
- **One shape for all answers:** an identity stays a single result, and gains an optional `signals` list when several are under the point. `identify_signal` and `get_cursor.signal` return that. An answer with one signal is the same as it is today, plus the new evidence.
- **`identify_signals` returns one row per signal, except slot modes.** A group of one slot mode, like 6 FT8 stations, is one row with `count`, its span and a `signals` list. It counts as one towards `max_signals`, so a scan logs one bookmark for the group, not six.
- `identify_signals` gains an `interference: true` flag on comb lines, and doesn't count them towards `max_signals`.
- **Scans wider than one capture keep their current dwell by default,** so they stay quick. They name from tone numbers alone, and say so in the result: no 16 s lookback, slot evidence or decode. A new optional `dwell_seconds` (at most 30) buys those. Scans within the current view use the ring as normal.
- Results carry any trial-decode text, treated as untrusted radio text like other decodes.
- The skill and tools reference are updated.

## Testing

**A real-signal corpus is the score.**
- **Clips in the repo:** short IQ clips from the owner's recordings, channelised small (about 4 MB each at most), in `Tests/SignalIDTests/Fixtures`.
- **Whole-capture context:** for bugs that depend on the 1 MHz context (lumping, the comb), each recording also contributes a small saved average spectrum.
- **Full recordings** stay on the owner's Mac. A test behind an environment variable runs against them.
- **A manifest** gives each test point: clip, frequency, time, what's true, and how we know (decoded, measured by hand, or the owner's say).
- **Who labels:** the builder labels from analysis done separately from the code under test, and records how in the manifest. FT8 truth comes from SubFloor's decoder. The owner reviews the manifest in the pull request and can correct it.
- **Keeping the test honest:** thresholds are tuned on the first part of each recording and asserted on the rest. Each new recording starts as unseen data, and is scored once before any tuning.
- **A window** is one identification: a chosen point at a chosen time, with the app's normal read ending there. Points step along each trace or area every 3 s, and only windows during a transmission count for "while transmitting".
- **What counts:** a single-trace point at close zoom must name the mode. The hover path, with no decode, must meet the targets below by itself; FT4 never has a decode anyway. The card path must do at least as well. A wider-zoom point that gets a group answer such as `FT8 · 9 signals` counts as naming FT8.

**Targets on the corpus:**

| Test | Target |
| --- | --- |
| FT8 traces, while transmitting | Named FT8 in ≥ 80% of windows; the FT8 truth checked first with SubFloor's own decoder |
| FT4 traces, while transmitting | Named FT4 in ≥ 80% of windows |
| The 11.688 MHz FSK | Called 2-FSK, shift within 3%, speed within 1%, in ≥ 80% of windows; not merged with its neighbour. First confirm the true speed by a second method, such as the keying line over the whole recording. If that can't confirm it to 1%, assert speed within 3% and say so |
| Empty points | `No signal` in ≥ 95% of points, and never a width over 100 kHz |
| Comb lines | Labelled comb or `No signal`, never named as a mode |
| Any point | No wrong name at ≥ 0.7 |
| Existing real voice fixtures | No worse than today |

**Still needed from the owner:** recordings of ham RTTY at 45.45 Bd / 170 Hz, CW and SSB on a busy band, and PSK31. Until there's a real clip, a mode's real-signal score reads "not tested", and the README says which modes have been tested on real signals. Work doesn't wait on these, and RTTY/FSK ships with the one real FSK signal plus synthetic tests.

**The synthetic suite stays** as a regression check, with these additions: neighbours, fading, a comb, level jumps and groups of FT8. Its figures are no longer the headline.

**Speed:** the default test run must not add load back to the full suite (rulings from the first build still apply: heavy sweeps sit behind `SUBFLOOR_SIGNALID_MATRIX=1`).

## Non-goals

- Decoding for its own sake: no new decoder, and no FT4 decoder. The decode output is evidence.
- Machine-learning classifiers. This remains a non-goal, though the corpus would make one possible later.
- Removing the comb from the display or the audio, or finding what causes it.
- A frequency calibration setting. The hints tolerate the error; a real setting could be a small separate job.
- Labelling every signal on screen continuously.
- Real-signal tuning of modes the owner hasn't recorded.
- Noise-floor and C/N markers, which follow this.

## Anti-goals

- **A confident wrong name.** Still the worst outcome.
- **Calling a real signal interference,** or hiding it.
- **A figure that sounds better than it is.** No accuracy claim from synthetic signals presented as how it does on the air.
- **Tuning to the two recordings until they pass** while real bands still fail. That's what the held-back parts and unseen recordings are for.
- **Hover that stutters the waterfall or the audio.**

## Also fixed here

- **After a failed hardware tune,** the note "Too soon after tuning — try again" stops after about 1 s, when the IQ is still at the old centre. It then says plainly that the radio isn't at the requested frequency. Trying again never helped.

## Calls made so far (the designer's, open to change)

- **Hover doesn't decode;** the card and agents do.
- **The owner's requests go first,** and the failed-tune note is fixed here, not in a separate job. Trial decodes make the queue matter, and both changes are in the same file.
- **Wide scans stay quick by default,** naming from tone numbers only; `dwell_seconds` buys the rest.
- **A group of one slot mode is one scan row and one bookmark.**
- **The comb needs at least 8 lines,** so a narrow capture never labels one.
- **The builder labels the corpus,** and you can correct it in the pull request.
- **The FSK's 1% speed target depends on confirming 75 Bd;** otherwise it's 3%.
- **"RTTY"** requires the ham segments or readable text. Non-ham FSK shows as `2-FSK` with numbers, even at standard RTTY speeds.
- **Group answers** at wide zoom, with the card listing each signal.
- **The 80% and 95% targets** are starting points; two recordings are too few to know what's achievable.
- **Hints allow about 2 kHz of error,** instead of adding calibration now.
- **The comb is only labelled.**
- **Ham RTTY isn't a blocker:** the design proceeds with no real clip of it yet.

## Left to the builder

- The spectrogram's resolutions, windows and neighbourhood sizes.
- Thresholds, including the "take turns" correlation, tuned as above.
- How to reuse or replace `Extent` and `SignalMeasurer` internals, as long as the behaviour above holds and the synthetic suite still passes.
- Clip selection and the manifest's format.
- The card's layout for the list of signals.
