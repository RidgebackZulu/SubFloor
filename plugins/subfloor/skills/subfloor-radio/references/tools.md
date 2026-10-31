# SubFloor MCP tools

Every tool SubFloor's MCP server offers, with its arguments and what it returns. A test in SubFloor
(`MCPPluginTests`) checks that this file has one section per tool and names every argument.

Conventions:

- **Frequencies are display Hz**, the frequency the listener means (with HamItUp on, SubFloor tunes the radio
  above it for you). Every frequency argument also takes a string: `"7.074 MHz"`, `"7074k"`, `"6925"`. A bare
  number in a string under 3000 is MHz, under 3 000 000 kHz; a JSON number is always Hz.
- **Levels are dBFS** (0 is full scale; the noise on HF is typically −120 to −90).
- **Times are ISO 8601, UTC.**
- Results are JSON with `"ok": true`. A failed precondition or bad argument is a tool error whose text says what
  to do, e.g. "The radio is stopped: call start_radio first." Out-of-range bandwidths, levels, counts and
  durations are clamped, not refused; a frequency or spectrum range the radio cannot reach is refused with an
  error.
- Tools that change the radio run one at a time, in the order called. Read-only tools (`get_*`, `list_*`,
  `search_transcripts`) answer at once, even during a `listen`.
- Modes: `am`, `nfm`, `wfm`, `usb`, `lsb`, `cw`. Default bandwidths and ranges (Hz): AM 8000 (2000–20000),
  NFM 12500 (5000–25000), WFM 180000 (50000–250000), USB/LSB 2700 (500–5000), CW 500 (50–3000).

## Radio

### `get_status`

The radio's state in one call. Call it first, and whenever unsure what the owner has changed.

No arguments.

Returns `running`, `source` (`rsp1b`, `demo` or `iq_file`), `device`, `vfo_hz`, `center_hz` and `span_hz` (the
capture: `get_spectrum` sees `center_hz ± span_hz/2`), `mode`, `bandwidth_hz`, `hamitup {on, lo_hz}`,
`squelch {on, level_dbfs}`, `signal_dbfs` (the passband's level now; null while stopped),
`recording {audio, iq, auto_state}`, `decoder` (`ft8`, `wspr`, `cw`, `psk31` or `off`),
`transcription {on, has_key}` and `mcp_clients`.

`auto_state` is `off`, `armed`, `recording`, `needs_squelch`, `needs_radio`, `demo_source` (Auto never records the
demo signal) or `paused`.

### `start_radio`

Starts the receiver on the owner's chosen source. If the RSP1B can't be opened, the demo signal runs instead and
`note` says so. If the RSP1B is still opening, it fails with "call get_status in a few seconds".

No arguments. Returns `{running, source, note?}`.

### `stop_radio`

Stops the receiver; any recording ends. Ask the owner before stopping a radio you didn't start.

No arguments. Returns `{running, source}`.

### `tune`

Tunes the receiver. A new mode takes its default bandwidth unless `bandwidth_hz` is given.

| Argument | Type | Description |
|---|---|---|
| `frequency` **(required)** | number or string | Display Hz, or a string like `"7.074 MHz"`. |
| `mode` | `am` / `nfm` / `wfm` / `usb` / `lsb` / `cw` | Demodulator. Omitted: left as it is. |
| `bandwidth_hz` | number | Passband width in Hz, clamped to the mode's range. |
| `hamitup` | `on` / `off` / `auto` (or true / false) | HamItUp upconverter. `auto`: on below 30 MHz (when reachable through it), otherwise left. Omitted: left as it is. |

The RSP1B tunes 1 kHz – 2 GHz; with HamItUp on, the top comes down by its LO (default 125 MHz). Out of range fails
without tuning. While an IQ recording is playing, only frequencies inside it can be tuned.

Returns `{vfo_hz, mode, bandwidth_hz, hamitup {on, lo_hz}}`: the tuning in effect.

### `set_squelch`

Turns the squelch on or off and sets its level. Either argument may be left out.

| Argument | Type | Description |
|---|---|---|
| `enabled` | boolean | Squelch on or off. |
| `level_dbfs` | number | Opening level in dBFS, −140 to 0 (clamped). |

Returns `{on, level_dbfs, signal_dbfs}`. Set the level a few dB (3–6) above the noise: see the skill.

### `get_cursor`

What the owner is pointing at, as three cursors:

- `mouse`: where the pointer last rested on the spectrum (kept after it leaves), with `seconds_ago`; null if never.
- `decoder_cursor`: the decoder's amber cursor (placed with a right click), with `audio_hz`, `decoder`, `snr_db`
  and `text`; null when no decoder is on or nothing is locked.
- `vfo`: the tuning, with `mode` and `bandwidth_hz`.

Each gives `hz`, `level_dbfs` (the live spectrum there; for the VFO, the passband's signal level),
`nearest_bookmark` (`{id, name, frequency_hz, offset_hz, mode}` within ± half the bandwidth, or null) and
`decodes_near` (decoder rows within ± half the bandwidth: `{hz, mode, snr_db, text, utc}`).

No arguments. It does **not** say what kind of signal is there (no modulation identifier yet): judge from the
level, the bookmark, the decodes, a `get_spectrum` around it, or a `listen`.

### `get_spectrum`

Power across a range, from the live averaged spectrum. Needs the radio running.

| Argument | Type | Description |
|---|---|---|
| `from_hz` | number or string | Lower edge, display Hz. Default: the owner's current view. |
| `to_hz` | number or string | Upper edge, display Hz. Default: the owner's current view. |
| `points` | integer | How many values, 16–2048 (default 512). |

The range must lie inside the capture (`get_status`: `center_hz ± span_hz/2`); outside it, the error says to tune
there first. Returns `{from_hz, to_hz, bin_hz, levels_dbfs, peaks}`: `levels_dbfs` has `points` values, each the
strongest bin in its slice; `peaks` lists up to 20 `{hz, level_dbfs, width_hz}` at least 6 dB above the window's
median, strongest first, with the width at −6 dB. The median of `levels_dbfs` is a fair noise-floor estimate.

## Listening and recording

### `listen`

Stays on the current frequency for `seconds`, then reports what came through. It doesn't hold the radio: if the
owner or another agent retunes, changes mode or stops the radio meanwhile, it stops early and returns
`{interrupted, seconds}`, e.g. `"retuned to 7.2 MHz by the owner"`. Needs the radio running.

| Argument | Type | Description |
|---|---|---|
| `seconds` | number | How long, 2–60 s (default 15). |
| `transcribe` | boolean | `false`: no transcript (default true, if the owner allows). |
| `keep` | boolean | `true`: save the clip as a recording in the owner's Recordings (default false). |

Returns `{seconds, level_dbfs {min, median, max}, squelch_open_seconds, transcribed, transcript?, note?, file?}`.
Levels are sampled every 200 ms. `squelch_open_seconds` is all of it when the squelch is off. `transcript` is
`{text, verdict, words, cost_usd?}`, `verdict` being `voice` or `possible_noise`; it comes only when the owner
has **Transcribe Recordings** on and an OpenRouter key saved (about $0.0001 per 15 s), and `note` says why
otherwise. Only the owner can turn transcription on.

### `start_recording`

Records the radio, starting the pre-roll ago (the owner's setting, 5–120 s), so the start of what you just heard
is kept. It stops by itself after `max_minutes`, or earlier if the owner stops it or the disk where recordings go
is nearly full (under 100 MB free; a start is refused then too). A second call moves the time limit of your own
recording. A recording the owner started is left alone. Needs the radio running.

| Argument | Type | Description |
|---|---|---|
| `kind` **(required)** | `audio` / `iq` / `both` | `audio`: what is heard (before the squelch fades it); `iq`: the whole capture (large files); `both`. |
| `max_minutes` | number | Stop after this many minutes (default 30, at most 240). |

Returns `{started, stops_at, note?}`.

### `stop_recording`

Stops the recordings agents started. The owner's own recordings keep running.

| Argument | Type | Description |
|---|---|---|
| `kind` | `audio` / `iq` / `both` | Which (default both). |

Returns `{stopped, note?}`.

### `set_auto_record`

Turns Auto-record on or off. Auto records each transmission that opens the squelch, so it needs the squelch on
(`set_squelch` first, or it fails with "Turn the squelch on first"). It records only while the radio runs on the
RSP1B and waits otherwise (`auto_state` says why: `demo_source`, `needs_radio`...).

| Argument | Type | Description |
|---|---|---|
| `on` **(required)** | boolean | Auto on or off. |
| `minutes` | number | With `on: true`: turn Auto off after this many minutes (default 60, at most 720). |

An agent's Auto turns itself off after `minutes`, even across a relaunch, unless the owner turns it off and on
meanwhile. If the owner had Auto on already, it stays on with no limit. `on: false` turns off only an agent's Auto;
the owner's is left on and the call fails saying so. Returns `{on, auto_state, off_at?, note?}`.

### `list_recordings`

The audio recordings in the owner's Recordings, newest first.

| Argument | Type | Description |
|---|---|---|
| `since` | string | ISO 8601 time, e.g. `"2026-10-31T14:00:00Z"`. |
| `until` | string | ISO 8601 time. |
| `frequency` | number or string | Only those within `tolerance_hz` of this display frequency. |
| `tolerance_hz` | number | How far from `frequency` (default 5000 Hz). |
| `voice_only` | boolean | Only recordings whose transcript verdict is voice. |
| `limit` | integer | At most this many (default 50, up to 500). |

Returns `{recordings}`, each `{file, start, seconds, frequency_hz, mode, auto, heard, in_progress, transcript}`;
`seconds` is null while unknown, `transcript` null or `{verdict, words, excerpt}`.

### `get_transcript`

One recording's transcript.

| Argument | Type | Description |
|---|---|---|
| `file` **(required)** | string | The recording's file name, from `list_recordings`. |

Returns `{file, verdict, text, words, start, frequency_hz, mode}`; `words` are `{text, start, end}` in seconds into
the recording. Fails if the recording has no transcript yet.

### `search_transcripts`

The same search as the Recordings window: the recordings whose transcript holds every word of the query (case,
accents and punctuation ignored), newest first.

| Argument | Type | Description |
|---|---|---|
| `query` **(required)** | string | Words to find. |
| `limit` | integer | At most this many (default 20, up to 200). |

Returns `{results}`, each `{file, start, frequency_hz, mode, verdict, excerpt}`.

## Bookmarks

A bookmark an agent adds carries the agent's name (`added_by`) and shows as **MCP** in SubFloor's bookmark
manager. Any agent may change or delete agent bookmarks; the owner's (`added_by` null) can only have notes
appended, and can never be deleted.

### `list_bookmarks`

The bookmarks, by frequency.

| Argument | Type | Description |
|---|---|---|
| `query` | string | Only those whose name, notes, group or added_by contain this (case-insensitive). |
| `group` | string | Only this group (case-insensitive). |

Returns `{bookmarks, groups}`; each bookmark is `{id, name, frequency_hz, mode, bandwidth_hz, hamitup, group,
notes, added_by, created}`.

### `add_bookmark`

Saves a bookmark, marked as added by you.

| Argument | Type | Description |
|---|---|---|
| `name` **(required)** | string | Short and clear, e.g. `"VOLMET Shannon"`. |
| `frequency` **(required)** | number or string | Display Hz, or a string like `"7.074 MHz"`. |
| `mode` | `am` / `nfm` / `wfm` / `usb` / `lsb` / `cw` | Default: the current mode. |
| `bandwidth_hz` | number | Default: the current bandwidth, or the mode's default for a new mode; clamped to the mode's range. |
| `group` | string | Group name; an existing group's spelling is matched. |
| `notes` | string | What, when, and the evidence. |
| `hamitup` | `on` / `off` / `auto` | HamItUp when the bookmark is tuned. Default: as it is now; `auto`: on below 30 MHz. |

The frequency must be tunable with that HamItUp setting. Returns `{id}`.

### `update_bookmark`

Changes a bookmark an agent added (any agent's). On the owner's bookmarks only `append_notes` is allowed.

| Argument | Type | Description |
|---|---|---|
| `id` **(required)** | string | The bookmark's id, from `list_bookmarks`. |
| `name` | string | New name (not empty). |
| `frequency` | number or string | New display frequency. |
| `mode` | `am` / `nfm` / `wfm` / `usb` / `lsb` / `cw` | New mode (takes its default bandwidth unless `bandwidth_hz` is given). |
| `bandwidth_hz` | number | New width, clamped to the mode's range. |
| `group` | string | New group. |
| `notes` | string | Replaces the notes. |
| `hamitup` | `on` / `off` / `auto` | New HamItUp setting. |
| `append_notes` | string | A line added to the end of the notes. |

Returns `{bookmark}`.

### `delete_bookmark`

Deletes a bookmark an agent added. The owner's can't be deleted.

| Argument | Type | Description |
|---|---|---|
| `id` **(required)** | string | The bookmark's id, from `list_bookmarks`. |

Returns `{deleted}` (the id).

## Decoders

SubFloor decodes every signal of the chosen mode inside the receiver's passband at once. FT8 and WSPR decodes are
kept for 30 days; CW and PSK31 are live only.

### `set_decoder`

Turns the decoder on in one mode, or off. Tune first: FT8 on 20 m is 14.074 MHz `usb`; WSPR on 30 m is
10.1387 MHz `usb`. FT8 and WSPR need a live source, not an IQ recording (`note` says so).

| Argument | Type | Description |
|---|---|---|
| `mode` **(required)** | `ft8` / `wspr` / `cw` / `psk31` / `rtty` / `off` | The decoder's mode, or `off`. `rtty` is not offered yet and is refused. |

Returns `{decoder, note?}`.

### `get_decodes`

What the decoder has heard.

| Argument | Type | Description |
|---|---|---|
| `since_minutes` | number | How far back (default 15, up to 10080: a week). |
| `mode` | `cw` / `psk31` / `rtty` / `ft8` / `wspr` | Only this mode. |
| `limit` | integer | At most this many decodes (default 200, up to 1000). |

Returns `{decodes, live, truncated}`. `decodes` are the FT8/WSPR messages, newest first, each `{utc, mode, hz,
audio_hz, snr_db, message, kind, from, to, grid}` (`from`, `to`, `grid` parsed from the standard message shapes;
null when not present). `live` are the CW/PSK31 signals being decoded now, each `{hz, mode, snr_db, text, cursor}`.

### `get_ft8_stations`

Every station heard calling in FT8, most recently heard first: the data for a map.

| Argument | Type | Description |
|---|---|---|
| `hours` | number | How far back (default 24, up to 168). |

Returns `{stations}`, each `{call, grid, lat, lon, best_snr_db, last_heard, count, bands}`. `lat`/`lon` are the
centre of the Maidenhead grid square; `grid`, `lat` and `lon` are null when the station never sent a grid.
