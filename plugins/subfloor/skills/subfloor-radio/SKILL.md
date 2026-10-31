---
name: subfloor-radio
description: Drive the SubFloor SDR receiver (an SDRplay RSP1B on macOS, optionally through a HamItUp upconverter) through its MCP server - tune a frequency, check what the owner's cursor is on, listen and transcribe, set the squelch above the noise, record, decode FT8/WSPR/CW/PSK31, map FT8 stations, hunt shortwave broadcasts and pirates, scan a band and log bookmarks. Use when the user talks about radio, SDR, a frequency, shortwave, HF, pirate radio, broadcasts, FT8, WSPR, callsigns, recording or bookmarks, or asks for SubFloor, and SubFloor's MCP tools (get_status, tune, listen...) are available.
version: 1.0.0
author: SubFloor
metadata:
  category: radio
  tags: "sdr, radio, shortwave, ft8, mcp, rsp1b, recording, bookmarks"
---

# Working the radio with SubFloor

SubFloor is a native macOS receiver for the SDRplay RSP1B. Its MCP server gives you hands (tune, record,
bookmark) and eyes and ears (spectrum, signal levels, decodes, transcripts). You do the research and the
reasoning: what is on a frequency, when a station is on air, whether what you hear is a real signal.

It is the owner's radio, and they may be listening while you work. There is one receiver: when you tune, they
hear it. Say what you are about to do before a long hunt or scan, note the tuning from `get_status` first, and
tune back to it when you finish unless they asked otherwise. SubFloor is receive-only: nothing you do transmits.

## 1. Connect

SubFloor must be running with its MCP server on: the **MCP** button in its top bar (or Radio › MCP Server…),
**Enable the MCP server**. The window's Setup tab has a ready snippet for each agent, with the URL and token
filled in. The server is `http://127.0.0.1:7824/mcp` (the owner can change the port) with
`Authorization: Bearer <token>`; with this plugin the token comes from `SUBFLOOR_MCP_TOKEN` (and the URL from
`SUBFLOOR_MCP_URL` if the port changed).

- A 401 means the token is wrong or was renewed: the owner copies the new one from the MCP window.
- Connection refused means the server is off, SubFloor isn't running, or it is on another port.
- While you are connected the MCP button glows and pulses with each call, and the window's **Event log** shows
  every call you make. The owner can switch the server off at any time.

**Start every session with `get_status`.** It tells you whether the radio runs, on which source (`rsp1b`; `demo`,
a built-in test signal around 14.1 MHz; or `iq_file`, a recording playing back), the tuning, HamItUp, the
squelch, recording and Auto, the decoder, and whether transcription is available. If the radio is stopped, call
`start_radio`. If the source is `demo`, the RSP1B isn't connected: tell the owner, because nothing you hear is
real.

## 2. Frequencies and HamItUp

- **Every frequency is a display frequency**: the one the listener means, as printed in schedules and logs.
  Give Hz as a number (`7074000`) or a string (`"7.074 MHz"`, `"7074k"`, `"6925"`: a bare number under 3000 in
  a string is MHz, so `"6925"` is 6925 kHz).
- **HamItUp** is an upconverter some owners put in front of the RSP1B for HF and below. With it on, SubFloor
  tunes the radio 125 MHz (its LO) above what you see; you still give display frequencies. The RSP1B covers
  1 kHz – 2 GHz on its own, so HamItUp is the owner's choice, not a requirement. Find out how this owner listens:
  `get_status` (`hamitup.on`) and their own HF bookmarks (`list_bookmarks`, `hamitup` on those below 30 MHz).
  If they use it, pass `hamitup: "auto"` with every `tune` (on below 30 MHz, left alone above); if not, leave
  `hamitup` out.
- **Modes**: shortwave broadcasters and most pirates are `am` (5 kHz steps); voice on ham bands is `lsb` below
  10 MHz and `usb` above; utility and military voice (VOLMET, HFGCS) is `usb`; digital signals are listened to
  in `usb` (a wide `bandwidth_hz`, up to 5000, to take in the whole signal); `cw` for Morse; `nfm`/`wfm` for VHF
  and FM broadcast.
- **The capture.** The radio sees a window `span_hz` wide around `center_hz` (`get_status`), and the VFO sits
  inside it. `get_spectrum` and `get_cursor` read only inside that window; to look elsewhere, `tune` there
  first. After a retune the averaged spectrum needs a second or two to settle: `listen` for 2–3 s
  (`transcribe: false`) before reading levels.

## 3. What is the owner's cursor on?

`get_cursor` gives three cursors: the **mouse** (where the pointer last rested on the spectrum, with
`seconds_ago`), the **decoder cursor** (the amber one placed with a right click) and the **VFO**. "My cursor"
usually means the mouse if `seconds_ago` is recent, else the decoder cursor, else the VFO; say which you used.

For each it gives the frequency, the level there, the nearest bookmark and any decodes near it. **It does not
say what kind of signal it is**: SubFloor has no modulation identifier yet (that comes in a later release). So
reason it out, and say how sure you are:

1. The **frequency**: what is allocated or scheduled there (a broadcast band, a ham band's digital segment, a
   known utility or number station). Search the web for the frequency and the time.
2. The **bookmark** and **decodes** near it: a named bookmark or an FT8/CW/PSK31 decode settles it.
3. The **shape**: `get_spectrum` over ±5 kHz around it with `points: 2048` and look at the peaks' widths.
   Rough guides: a lone line under 100 Hz wide is a carrier or CW; ~2.5–3 kHz with no carrier is SSB voice or a
   wideband data modem (MIL-STD/STANAG, ALE bursts); two lines 170 Hz apart is amateur RTTY, 425/450/850 Hz
   apart is utility FSK; a ~60 Hz trace among others in a 3 kHz block on 7.074/14.074 MHz is FT8; 8–10 kHz
   with a strong centre carrier is AM broadcast; a flat-topped 10 kHz block is DRM.
4. If the owner agrees to a retune, `tune` there in a suitable mode and `listen`: the level, how long the
   squelch opened, and a transcript tell voice from data.

## 4. Listening before recording (squelch above the noise)

Never record blind. Check that there is a signal, and set the squelch so it opens for the signal and not for
the noise.

1. **Measure the noise.** SubFloor has no measured noise floor yet (a later release adds one), so estimate it:
   `listen` (10–15 s, `transcribe: false`) on the frequency while the station is off air, or a few kHz away in
   a clear spot of the same band in the same mode and bandwidth. Its `level_dbfs.median` is the noise in the
   passband, on the same scale as the squelch. (`get_spectrum`'s median shows the band's floor and how far
   peaks stand above it, but it is per-bin power, not passband power: don't compare it directly with the
   squelch level.)
2. **Measure the signal** the same way while it is on: `level_dbfs` min/median/max.
3. **Set the squelch** with `set_squelch {enabled: true, level_dbfs: noise median + 3 to 6 dB}`, and below the
   signal's median. If the signal is less than ~6 dB above the noise, the squelch will chop it: leave the
   squelch off and record with a time limit instead.
4. **Check**: `listen` again; `squelch_open_seconds` should be close to `seconds` while the station is on, and
   near 0 when it is off.

To record: `start_recording {kind: "audio", max_minutes: <the broadcast's length + a few>}`. The recording starts
the pre-roll ago (5–120 s, the owner's setting), so the start is not lost. Or, to catch transmissions that come
and go on one channel: `set_auto_record {on: true, minutes: N}` (needs the squelch on; records only on the
RSP1B, not the demo). Use `kind: "iq"` only when asked: IQ files are large.

**At a set time.** SubFloor can't yet start a recording at a later time on its own (a Scheduler is coming in a
later release). So:

- If the broadcast is on now or within your session, wait for it (if your harness lets you wait), tune a few
  minutes early, check the noise, set the squelch, and start the recording with a `max_minutes` that covers it.
- If it is hours away, say so plainly. Offer: the owner asks you again near the time; or you bookmark it with
  the schedule in the notes; or, if the owner agrees to leave the radio there, tune now, set the squelch above
  the noise, and `set_auto_record {on: true, minutes: <until the end, at most 720>}` so Auto records it when the
  squelch opens.

## 5. Hunting (broadcasts, pirates, propaganda)

**Research first.** Schedules come from the web: current EiBi, HFCC, Aoki and Short-wave.info lists for
broadcasters, and recent loggings (HF Underground for pirates, broadcast DX clubs and logs) for what was
actually heard lately. Schedules change twice a year (the A season from late March, B from late October) and
stations come and go, so check that a schedule is current and say how old your sources are. Times are UTC.

**Propaganda and state broadcasters**: list each station, frequency, UTC times, language and target area, from
current sources, and say which you could verify on air. Verifying: at a scheduled time, tune, `listen` with
transcription, and compare language and content. Jamming (a rough wideband noise or a warble over the station)
is worth noting too.

**Pirates** are unlicensed hobby stations, mostly AM (some USB), on weekends and evenings and around holidays.
North American pirates gather around 6925 kHz (6.9–7.0 MHz); European ones around 6.2–6.4 MHz and 3.9–4.0 MHz.
Others turn up elsewhere: search recent loggings for what is active. To hunt:

1. Tune the band's centre and `get_spectrum` over it; the peaks are candidates.
2. For each candidate: `tune` in `am` (try `usb` if it sounds like SSB), then `listen` for 15–30 s with
   transcription (when `get_status` shows `transcription.on` and `has_key`).
3. **Keep only real stations.** It is real when the level stands well above the noise (6 dB or more over your
   noise median), the squelch stayed open for most of it, and the transcript's verdict is `voice` with words
   that make sense (station IDs, an email address, a song's words, announcements). `possible_noise`, a few
   stray words, or text that repeats is noise or Whisper hallucinating: move on. Music may come back with
   little text: judge it by the steady level and a strong carrier.
4. For a real one: `start_recording {kind: "audio", max_minutes: 30}` or, for a short sample,
   `listen {seconds: 60, keep: true}`; and log it (section 6).

Without transcription, decide by level and squelch alone and say the verdict is less certain.

## 6. Logging (bookmarks with notes and evidence)

Before adding, `list_bookmarks` (with `query` or `group`) so you don't duplicate one; update yours instead.

- **name**: short and specific: `"Shannon VOLMET 5505"`, `"HFGCS 11175"`, `"Pirate 6925: <station ID>"`.
  For an identification you are unsure of, say so: `"Possible STANAG 4285"`.
- **group**: existing group names are matched; otherwise pick a clear one (`"Pirates"`, `"Broadcast"`,
  `"Utility"`, `"Scan 4–7 MHz 2026-10-31"`).
- **mode**, **bandwidth_hz** and **hamitup** as you heard it, so a click on the flag brings it back.
- **notes**: what it is, when (UTC date and time), and the evidence: level vs noise, how long the squelch
  opened, transcript excerpt, decodes, spectrum width/shift, and the source of the schedule.

Your bookmarks are marked as added by you (**MCP** in the owner's bookmark manager). You may edit or delete any
agent's bookmarks. On the owner's own bookmarks you may only `append_notes` (e.g. "heard 2026-10-31 18:00Z,
S/N 12 dB, English"), never rename, move or delete them.

**Scanning a band** (for example 4–7 MHz for digital signals): the capture is `span_hz` wide, so step through:
tune to the band's low edge + half the span, read the spectrum over the capture, then step by about the span.
For each window: `listen {seconds: 2, transcribe: false}` to let the spectrum settle, then `get_spectrum` over
the capture with plenty of `points` (2048 for a 2 MHz capture is ~1 kHz a point; zoom in on a candidate with a
narrower range for detail). For each peak, look closer (±5 kHz, 2048 points), judge the type from its shape
(section 3) and, if it is worth it, tune and `listen`. Log each with "possible" where unsure; there is no
modulation identifier yet, so never present a guess as an identification. Tell the owner how many you found
and what you could not identify.

## 7. FT8 maps

SubFloor keeps every FT8 and WSPR decode for 30 days. `get_ft8_stations {hours: 24}` (up to 168) returns each
station: call, grid, its centre lat/lon, best SNR, last heard, count and bands. If it is empty, nothing was
decoded: offer to `tune {frequency: "14.074 MHz", mode: "usb"}` (20 m by day; 7.074 MHz 40 m by night;
others: 3.573, 10.136, 18.100, 21.074, 28.074 MHz) and `set_decoder {mode: "ft8"}`, then wait a few 15-second
slots.

To draw the map, write a single HTML file with Leaflet (e.g. `https://unpkg.com/leaflet@1.9.4/dist/leaflet.js`
and its CSS) and OpenStreetMap tiles: a marker per station with a lat/lon, coloured by `best_snr_db`, with a
popup (call, grid, SNR, last heard, count, bands); list stations without a grid beside the map. Save it where the
owner can open it (and open it if you can). The grid is the centre of a ~110 × 220 km square, not an address.

`get_decodes` gives the individual messages (`from`, `to`, `grid`, SNR) when you want who worked whom.

## 8. Callsigns

Look callsigns up on the web: QRZ.com (the details need a login), HamQTH, HamCall, or the national regulator's
licence database. The prefix gives the country (ITU allocations). Check the grid from the decodes against what
the lookup says. Never invent a name or address; give only what the lookup shows, and remember these are private
people.

## 9. Limits

- **Receive only.** Nothing transmits.
- **No scheduler yet:** you can't arrange a recording for a later time; you must stay running, or the owner waits
  for the Scheduler release (section 4).
- **No modulation identifier yet:** `get_cursor` gives the level, bookmarks and decodes, not "this is RTTY".
- **No measured noise floor yet:** use `listen`'s median as the noise estimate (section 4).
- **Recordings always end:** `start_recording` stops after `max_minutes` (default 30, at most 240); an agent's
  Auto turns off after `minutes` (default 60, at most 720). Pick a limit that fits; never leave a recording
  running with no reason. Stop yours with `stop_recording` when done.
- **The owner wins:** recordings, Auto and bookmarks the owner made are left alone; agents never delete a
  recording. If the owner retunes during a `listen`, it stops and tells you who changed what.
- `listen`: 2–60 s. Transcripts only when the owner has Transcribe Recordings on and a key saved (about
  $0.0001 per 15 s); you can't turn it on.
- Decoders offered: FT8, WSPR, CW and PSK31 (RTTY isn't yet). FT8 and WSPR need a live source.
- `get_spectrum` only inside the current capture.

## 10. Tool reference

See [references/tools.md](references/tools.md) for every tool, its arguments, limits and results.
