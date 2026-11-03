# The scheduler: design

**Status:** draft for approval, 2026-11-03

Decisions marked **(user)** came from the owner. **(designer's call)** marks a default chosen while designing that the owner has not ruled on; it may be changed.

## Why

The owner wants SubFloor to catch broadcasts by itself, overnight and while they're away, and have them waiting in the morning. Their targets, in their words: "pirates mostly, but I know they are random, but bigger popular shows, propaganda. No religious stuff at all." **(user)**

The owner listens from **Dallas, Texas**. **(user)**

The original request, from the job list: "research a specific radio broadcast, and then at that time auto tune and auto record, make sure to set the squelch above the noise floor so you don't record useless noise", and "research propaganda radio stations and schedule". Job 5, the noise-floor and C/N markers, was dropped, so the scheduler measures the noise floor itself.

**Success:** after a night unattended with the scheduler on:
- every scheduled broadcast that was on the air is one recording, labelled with its station, with an English transcript;
- every pirate who came on in the watched stretch is a recording;
- a station that was off air left nothing behind, not an hour of hiss;
- and anything that didn't happen says why.

## Goals

- **Two kinds of schedule.** **(user)**
  - **Broadcasts:** a station at a known time on one or more frequencies, for propaganda and big shows.
  - **Pirate watches:** a stretch of the band watched for a time window. SubFloor jumps to whoever comes on and records them.
- **SubFloor runs the schedules itself.** A 3 a.m. recording happens with no agent running. **(user)**
- **The squelch sits above the measured noise floor**, so dead air records nothing. **(user)**
- **Two ways to add schedules, both wanted:** **(user)**
  - agents over MCP;
  - a built-in shortwave timetable the owner browses in SubFloor, adding a broadcast with a click.
- **No religious broadcasts, ever**, however a schedule is found. **(user)**
- **Transcripts in English.** Recordings in other languages are translated, and each transcript says what language was spoken. **(user)**
- **The Mac stays awake** while a schedule is coming up. **(user)**

## What the owner sees

### The Schedule button

The button sits in the top bar, just right of Recordings. The approved mockup is at https://claude.ai/artifact/MTFdv5UbqcUTRyGSg3j6Qi (private to the owner). It has two parts:

- **The left part (clock icon, "Schedule") turns the whole scheduler on or off.** **(user)**
  - While it's on, schedules take the radio at their time, whatever the owner is doing. While it's off, nothing runs. **(user)**
  - There is no per-broadcast skip: the switch is the only control. **(user)**
- **The ticker box** scrolls what's coming up, e.g. `next 21:00 · Voice of Korea · 9435 kHz · then 23:30 · Radio Habana Cuba · 6000 kHz`. **(user: a ticker with the station and frequency)**

It has five states, as in the mockup:

| State | Look | Ticker |
| --- | --- | --- |
| Off | Grey, dimmed | `off · 4 schedules waiting` |
| On, next one later | Calm cyan outline | The coming broadcasts and watches, in order |
| Coming up soon | The whole button pulses cyan **(user)** | `in 4:32 · Voice of Korea · 9435 kHz AM · click to start now` |
| Recording on schedule | Red, like the other record buttons, with the elapsed time | Station, frequency, end time, and how far the squelch sits above the noise |
| Pirate watch | "Watching", cyan, with an eye icon | `pirates · 6925 kHz USB · quiet now · 2 caught tonight · until 02:00` |

- **The pulse** starts **5 minutes** before a broadcast or watch begins **(designer's call)**. It's a heads-up only. **(user)**
- **Clicking the ticker while it pulses** tunes now and starts that schedule early. **(user)**
- **Cyan** is the scheduler's colour, so it isn't mistaken for recording red. **(designer's call)** In the Recording state the left part shows the elapsed time, and clicking it stops this run (see *The owner during a run*).
- **Right-click** the button, or use the Window menu, to open the Schedules window. **(user)**
- **When the top bar is too narrow,** the ticker hides first and the button stays. **(designer's call)**

### The Schedules window

A window like Recordings (`Window("Schedules", id: "schedules")`), with two tabs. **(user)**

**My schedules** lists every schedule, whether the owner or an agent added it. Each row shows:
- the station or watch name;
- the frequencies or span, and the mode;
- the days and time, shown in Dallas local time with UTC beside it;
- the next run;
- an on/off switch;
- who added it (`you`, or the agent's client name);
- and the **last run's outcome**: `Recorded 28 min` · `Nothing heard: the squelch never opened` · `Missed: the RSP wasn't connected` · `Missed: SubFloor wasn't running` · `Missed: the Mac was asleep` · `Stopped by you` · `Overlapped with Radio Habana Cuba`.

Rows can be edited and deleted, and new ones added by hand.

The window also carries two notes:
- the **keep-awake note** (see *Keeping the Mac awake*);
- a note when transcription is off in Settings, since scheduled recordings then get no transcripts.

**Timetable** is the built-in shortwave list (see *The timetable*), for broadcasts aimed at North America.
- Each broadcast shows its station, language, local and UTC time, days, and frequencies.
- It can be searched by station, language or country, and has an **On tonight** filter (the next 24 hours, local).
- Each broadcast has an **Add** button. It creates a broadcast schedule with all its frequencies, its days, and AM.
- Religious broadcasts never appear.
- A line credits EiBi and says how old the list is.

### In the morning

- Every scheduled recording is in the Recordings timeline as usual, labelled with its schedule's name (`Voice of Korea`, `Pirate watch`) **(user)**. Its transcript is in English, headed with the language spoken (`Translated from Korean`).
- The Schedules window says what happened to each run.

## How it works

### Schedules

A schedule holds:
- `id`;
- `kind`: `broadcast` or `watch`;
- `name`;
- **broadcast:** `frequenciesHz`, 1–8 of them;
- **watch:** `lowHz` and `highHz`, 10–400 kHz wide, inside one capture;
- `mode`: `am`, `usb`, `lsb` or `auto` (watches default to `auto`, broadcasts to `am`);
- `start`: a time of day, plus a `duration`;
- `timeZone`: `UTC` for timetable broadcasts, the owner's local zone otherwise, so a weekend evening watch stays at 7 p.m. through daylight-saving changes;
- `days`: a set of weekdays, the nth or last weekday of the month, or `once` on a date; with an optional start and end date;
- `timetableKey`: set when the schedule came from the timetable (see *The timetable*);
- `enabled`;
- `squelchMarginDb`, default 8 (see below);
- `addedBy`: nil for the owner, else the MCP client;
- `source`: `timetable`, `agent` or `you`;
- `created`;
- `lastRun`: its outcome and time.

- **Repeats:** daily, chosen weekdays, or once. **(user)**
- **Store:** `~/Library/Application Support/SubFloor/schedules.json`, built the way `BookmarkStore` is: a versioned wrapper, atomic writes, the corrupt file kept aside with a banner, and saving blocked if it can't be kept.
- **The master switch** is saved in the session. It's off on first launch.
- **The default pirate watch** is created on first launch, switched off: `Pirates`, 6900–7000 kHz **(user)**, Friday and Saturday 19:00–02:00 local **(designer's call)**, mode `auto`.

Pirates also turn up below 6900 kHz. EiBi lists pirate channels at 6850–6915 kHz, and logs show 6800–6990 kHz. The default stays at 6900–7000 kHz, as agreed. The span is editable and can be widened to 6800–7000.

### The run engine

A `Scheduler` service on the main actor, owned by `AppModel` like `SignalIDService`, checks the clock once a second.

- **Waking late:** a Mac that slept past a start, or SubFloor launched mid-window, starts the run late for the rest of its window. One that missed the whole window logs it as missed.
- **Starting the radio:** if the radio is stopped when a run starts, the scheduler starts it. If the RSP isn't there, the run is logged as missed and a banner says so.
- **Before a run:** the scheduler saves what the radio was doing:
  - the VFO and centre;
  - the mode and bandwidth;
  - the squelch;
  - Auto, and whether its time limit is the owner's or an agent's;
  - HamItUp;
  - whether the radio was running.
- **After a run:** it puts all of that back, including stopping the radio if it had been stopped. **(designer's call)**
- **HamItUp:** set the way the MCP tools' `auto` does: on below 30 MHz.
- **Silent runs:** the live audio is muted for the whole of a run, and unmuted when it ends. **(user)** Recording is unaffected, since it taps the audio before the speakers. Exception **(designer's call)**: a run the owner starts early by clicking the ticker plays as usual, because they're at the Mac.
- **Recording:** reuses Auto-record's machinery: its squelch gate, its pre-roll, its *start after* and *keep gaps* timing, and its pop filter. Audio only, no IQ. **(user)**
  - **A broadcast is one file (designer's call).** The file opens when the squelch first opens, and stays open until the window ends. Quiet stretches longer than *keep gaps* are written as silence, the way Auto writes a long gap today; FLAC packs silence small.
    - Auto's *stop after* doesn't apply. That keeps a fading overnight broadcast in one file, with one transcript.
    - The file closes early only after **10 minutes** of quiet, so a station that leaves early doesn't leave a long silent tail. If it comes back, that makes a second file.
  - **A pirate watch makes one file per transmission,** using Auto's *stop after* as it is.
- **The source:** a schedule always uses the RSP. **(designer's call)**
  - If the owner is on Demo or playing an IQ file, the run switches to the RSP, and the source is restored afterwards with the rest.
  - If the RSP can't be opened, the run is logged `Missed: the RSP wasn't connected`. That includes `start()`'s silent fallback to Demo.
  - Auto's rule that it never records the Demo source holds for schedules too. The tests drive runs through an injected source seam, not by letting Demo record.
- **Labels:** each recording's log entry gains an optional `schedule` object, `{id, name}`, a new optional key in `RecordingLogEntry`. Old logs still decode. The catalog and Recordings timeline show the name.
- **Taking the radio:** when a schedule starts, it takes the radio from whoever has it. **(user: "if I have the scheduler enabled, then it wins")**
  - **The owner:** an owner's manual recording is stopped (its file is kept), and the owner's Auto is paused for the run.
  - **Agents:** an agent's scan, listen or recording is interrupted, with the reason `a schedule took the radio`.
  - **During a run,** agent tools that would tune refuse with `SubFloor is recording a scheduled broadcast until 21:30` (or `is on a pirate watch`). Read-only tools still work.

### The owner during a run

**(designer's call)** If the owner retunes, changes mode, or starts a recording of their own during a run, that run ends as `Stopped by you`, and the scheduler doesn't take the radio back.
- A watch stays stopped until its next window.
- Turning the master switch off also ends a run.
- Clicking the left part during a run stops that run only.

The owner said the scheduler wins when a schedule starts. A change made mid-run is the owner at the radio, and fighting them would be worse than missing the rest of the broadcast.

### Squelch above the noise floor

The squelch compares channel power, in dBFS after the channel filter, so it depends on mode and bandwidth. The floor is therefore measured after the mode and bandwidth are set.

**How the floor is measured (designer's call):**
1. From the spectrum, the scheduler picks 2–3 quiet spots within ±50 kHz of the frequency: bins near the local median, away from any peak.
2. It moves the VFO to each one (`setVFO`, with no hardware retune) for about 3 s, squelch open, and reads the channel level (`signalDb`).
3. The floor is the median of those readings.

Measuring off the frequency means a station that's already on the air doesn't count as noise. The squelch is then set to **floor + `squelchMarginDb`**, default **8 dB**. **(designer's call)** The ticker shows the margin.

**When it's measured:**
- **Broadcasts:** 60 s before the start. The radio is the scheduler's from then on.
- **Watches:** at the start, then again every 10 minutes while nothing is being recorded, since the noise changes through the night.

The offline replay tool's `--above-floor` (S/AutoRecordReplay) is the only existing floor-plus-margin code. It's a reference, not something to reuse as is.

### Broadcasts

- **The window:** starts 1 minute before the timetable's start and ends 2 minutes after its end, since timetables are approximate. **(designer's call)**
- **One frequency:** tune, measure the floor, set the squelch, and record until the window ends.
- **Several frequencies:** only the strongest is recorded. **(user)** In the first 30 s after the broadcast's start, the scheduler reads each frequency's level against its floor and picks the one furthest above it. If none is above, it stays on the first.
  - It doesn't switch again during the run. **(designer's call)**
  - The hops cost up to about 30 s at the start, and only when there's more than one frequency.
- **Off air:** if the squelch never opens, there's no file, and the run is logged `Nothing heard`.

### Pirate watches

- **Setting up:** the capture is centred so the whole span fits inside its usable part. A span of up to 400 kHz fits the default 2 MS/s capture.
- **While watching:** the scheduler reads the spectrum about once a second (`spectrumSnapshot()` and a `SpectrumSlice` over the span). Its floor is the median of the span.
- **A candidate** is a peak at least 10 dB over the span's floor that stays for at least 3 s, and is wider than a bare carrier.
- **Confirming:** the candidate goes to Signal ID at background priority. Only a voice-like answer starts a recording **(user)**: family `am`, `usb` or `lsb`, or `fm` with a voice envelope.
  - Carriers, data (`fsk`, `psk`, `mfsk`, `ofdm`, `ook`) and noise are ignored.
  - A rejected spot isn't checked again for 10 minutes.
- **Recording:**
  - The VFO moves to the station (`setVFO`, with no hardware retune).
  - The mode comes from Signal ID's family (AM, USB or LSB), with that mode's default bandwidth.
  - The squelch is set from that spot's floor.
  - It then records until it has been quiet for *stop after*, and goes back to watching.
- **Two at once:** only one station is recorded at a time: the first one found stays until it ends. **(user)**
- **The first seconds are lost.** Detection plus Signal ID takes about 5 s, and the audio before the jump was never demodulated at that frequency, so the pre-roll doesn't cover it. Re-demodulating the IQ ring to recover it is a non-goal for now.
- **The edges:** the 40 m ham band starts at 7000 kHz. Peaks within 3 kHz of the top edge are ignored, so ham CW at 7000.0+ doesn't count.

### Overlaps

There is one radio, so only one schedule runs at a time. **(designer's call)**
- A broadcast beats a watch. The watch pauses and resumes after the broadcast.
- Between two broadcasts, the one already running keeps the radio. The other is logged `Overlapped with <name>`.
- When two start at the same moment, the one added first wins.

The Schedules window marks overlaps when a schedule is added or edited.

### Keeping the Mac awake

- **While the scheduler is on and any enabled schedule runs in the next 24 hours,** SubFloor holds an activity that stops idle system sleep. The display may still sleep.
- **While a run is active,** it holds the stronger `.userInitiated` activity, as Auto does today.
- **The keep-awake note** in the Schedules window says that a Mac with its lid closed and no external display sleeps anyway, and that SubFloor has to be open. It turns amber when the Mac is on battery.
- **Waking a sleeping Mac** (`pmset schedule`) needs administrator rights and is a non-goal.

### The timetable

**Source: EiBi** (http://eibispace.de/), the season file `sked-<season>.csv`. The current one is `sked-b26.csv`. A is summer, from the late-March clock change; B is winter, from late October.
- Its terms say anyone may download, use, copy or distribute the files and use them in third-party software. Credit Eike Bierwirth / EiBi.
- The file is Latin-1, semicolon-separated with no quoting, and CRLF. The first line is a header with column widths and is skipped. There are 11 fields:
  1. kHz
  2. `HHMM-HHMM` UTC, which can cross midnight
  3. days
  4. ITU country
  5. station
  6. language
  7. target
  8. transmitter site
  9. persistence
  10. start date
  11. stop date
- **Bundled and updated:**
  - A copy of the current season's file ships in the app, so the timetable works offline. It's about 490 KB.
  - A weekly check fetches the file using `Last-Modified`/`ETag`, and moves to the next season's file at the changeover, falling back to the other season on a 404.
- **HTTP only:** eibispace.de's HTTPS certificate has expired, so the fetch is plain HTTP. That needs an App Transport Security exception for that one host.
- **Untrusted data:** the file is parsed strictly. Rows that don't parse are dropped and counted.
- **Filters:**
  - **Target:** NAm, ENA, CNA, WNA, Am, Car, CAm, or USA. EiBi's README doesn't list NAm and CAm, but the data uses them.
  - Rows with persistence 8 (inactive) or 90 and above (utility stations) are dropped.
  - Rows flagged `irr`, `tent` or `test` show as uncertain.
- **Days:** the field holds empty (daily), day names and ranges (`Tu-Fr`), digit strings (`1245`, Monday = 1), first or last weekday of the month (`1.Sa`, `Last7`), alternate weeks (`altFr`), dates (`15Sep`), and flags mixed in (`alt`, `irr`, `USB`, ...). Anything that isn't a day is a flag.
  - Days are in UTC. A Dallas evening falls on the next UTC day.
- **One broadcast:** rows with the same station, language, time and days merge into one broadcast with several frequencies.
- **Schedules stay tied to the timetable (designer's call).** A schedule added from the timetable keeps a `timetableKey`: station, language, and the season it came from.
  - On each timetable update, including the seasonal changeover, the scheduler looks the broadcast up again.
  - **Found with new times or frequencies:** the schedule is updated to match. Its row says `Updated from the timetable` with the date.
  - **Not found:** the schedule is switched off, and its row says `No longer in the timetable`.
  - That way a copied schedule never goes on recording `Nothing heard` all season.
- **Day forms the model can't hold:**
  - The schedule model also allows the **nth or last weekday of the month** (`1.Sa`, `Last7`), and an optional **start and end date**, taken from EiBi's date fields.
  - Alternate weeks (`altFr`) and irregular rows are added as weekly schedules marked `Irregular in the timetable`.
  - Single dates (`15Sep`) are added as `once`.

### No religious broadcasts

There is no religious flag in EiBi, so it's a rule SubFloor applies everywhere: the timetable, `search_timetable`, and `add_schedule` / `update_schedule`. **(user)**

**The rule:** a station name matching the denylist or a keyword is religious. **(designer's call)**
- **The denylist:** Trans World Radio, Adventist World Radio, FEBC, Radio Vaticana / Vatican, Bible Voice, Follow the Bible, Hope Radio, Brother Stair, Voz Missionaria, Mystery for Joy, Hope of Israel, Evang. Missionsgemeinden, HCJB, Family Radio, KNLS, Voice of Hope, and the religion-heavy time-brokers WWCR, WTWW and WINB.
- **The keywords:** Bible, Gospel, Christ, Faith, Mission, Vatican, Adventist, Evang, Jesus, Church, Catholic, Islam, Quran, Hope.
- **Kept on purpose:** WRMI and WBCQ are time-brokers that also carry secular shows, including pirate-style programmes. An allowlist overrides keyword false positives such as `Hopen Island Meteo`, and `Sound of Hope`, which is political, not religious.
- **Where it lives:** a data file in the repository, reviewed each season.
- **Agents:** `add_schedule` with a religious station name is refused (`The owner doesn't want religious broadcasts`). The tool descriptions say so up front.

### Transcripts in English

Today, transcription asks Whisper (via OpenRouter) for one set language, `en` by default.

**Language detection:**
- Scheduled recordings are always sent with the language left to auto-detect.
- The language Whisper reports (`verbose_json` returns it) is stored in the transcript as `spokenLanguage`.

**Translation:**
- When the spoken language isn't English, a second OpenRouter call translates the transcript into English, segment by segment, keeping the timestamps.
- Both texts are stored. `StoredTranscript` goes to version 2, with optional `spokenLanguage` and `translation` fields; version 1 still reads.
- The player and transcript strip show the English, with `Translated from Korean` and a switch to the original. Search covers both.

**Settings:**
- A new Transcription setting, **Translate other languages into English**, defaults to on. It applies to any recording transcribed with auto-detect, not only scheduled ones. **(designer's call)**
- The translation model is a setting next to the Whisper model, using the same OpenRouter key. The builder picks a current low-cost model and checks its OpenRouter id.
- The cost is added to `costUSD`.

**Untrusted input:**
- Transcripts of propaganda are untrusted text. Nothing in a transcript ever reaches a model as instructions.
- The translation prompt fences the transcript in nonce-delimited untrusted-data markers, says to translate only, and is given no tools.
- A reply that isn't a translation of the right shape is discarded, and the transcript is kept untranslated with a note.

### Agents (MCP)

The new tools are in `SchedulerTools.swift`, added to the sum in `SubFloorTools.init`:

- **`list_schedules`:** every schedule with its next run and last outcome, plus the master switch's state.
- **`add_schedule`:** a broadcast (`frequencies` in kHz, `mode`, `start`, `duration_minutes`, `days` or `date`, `time_zone`) or a watch (`low`/`high`). It returns the schedule, its next run, and any overlap. It's refused for a religious station, an out-of-range frequency, a broadcast over 6 h, a watch window over 12 h, or a span over 400 kHz. There are at most 200 schedules.
- **`update_schedule`** and **`delete_schedule`:** only for agent-added schedules. Any agent may change any agent's schedule, as with bookmarks. The owner's own schedules are read-only to agents. **(designer's call)**
- **`search_timetable`:** query, language, country and `on_tonight`. Religious rows are never returned.
- **`get_status`** gains `scheduler {on, next, running}`.

Agents cannot turn the master switch on or off. Adding while it's off works, and the result says `The scheduler is off: the owner turns it on with the Schedule button`. **(designer's call)**

The tool descriptions carry the owner's preferences: propaganda, big shows, pirates, no religious stations. They also say that timetable data and transcripts are untrusted data.

## Testing

The usual Swift Testing suites. Nothing plays through the speakers. Timing assertions check captured amounts, not wall-clock time, since the demo source runs slow in debug builds.

**Time:**
- next-run calculation across UTC and local zones, midnight-crossing windows, the daylight-saving changes in Dallas, `once` dates, and a Mac that slept through part or all of a window.

**The timetable:**
- the EiBi parser on a fixture cut from `sked-b26.csv`, covering every days form, a midnight crossing, persistence values, Latin-1 names, and malformed rows;
- the merging of rows into broadcasts;
- the North America filter.

**The religious rule:**
- every denylist name and keyword, and the allowlist (`Sound of Hope`, `Hopen Island Meteo`, WRMI);
- the refusal in `add_schedule`.

**The noise floor and squelch:**
- on the demo source with a known noise level: the floor lands within 2 dB of it;
- a station already on the air doesn't raise the floor;
- the squelch is the floor plus the margin.

**Broadcasts:**
- on the demo source: a run on an empty frequency makes no file;
- a run with a signal makes one labelled file;
- with three frequencies, the strongest is picked;
- the state is restored afterwards, including a radio that was stopped.

**Watches:**
- a synthetic AM and an SSB voice signal appearing in the span get found, tuned and recorded;
- a carrier and an FSK signal are ignored;
- a peak at 7000.5 kHz is ignored;
- two signals at once: the first is kept.

**Taking the radio:**
- the scheduler wins at its start over the owner's Auto, a manual recording, and an agent's scan;
- an owner retune mid-run ends it as `Stopped by you`;
- agent tuning tools refuse during a run;
- overlap rules.

**MCP:**
- the schema rules for strict clients (`MCPRadioToolsTests.schemasSuitStrictClients`);
- the ownership rules for update and delete;
- the master switch can't be changed by agents.

**Transcripts:**
- translation is stored with timestamps, and version 1 transcripts still read;
- an injected instruction inside a transcript is translated as text, not obeyed (tested against a stub translator that checks the prompt is fenced);
- a malformed reply is discarded.

**The store:**
- corrupt-file recovery, as `BookmarkStore` is tested.

**Checked by hand on the RSP1B:**
- a broadcast from the timetable recorded overnight, with its English transcript;
- a weekend pirate watch.

## Non-goals

- Waking a sleeping Mac, or launching SubFloor at login.
- Recording two stations at once, or IQ recording from a schedule.
- A pirate schedule feed. None exists: pirate logs are forum posts.
- SubFloor researching broadcasts itself. That's an agent's job over MCP.
- Recovering the first seconds of a pirate from the IQ ring.
- Notifications to the owner's phone.
- The noise-floor and C/N markers (job 5, dropped).

## Anti-goals

- **Hours of hiss** from a station that wasn't on.
- **A religious broadcast** appearing anywhere: in the timetable, in an agent's results, or as a schedule.
- **The scheduler fighting the owner:** retuning back after the owner has changed something mid-run.
- **Silent failure:** a missed broadcast with no reason given.
- **A transcript or timetable row acting as instructions** to any model or agent.

## Calls made so far (the designer's, open to change)

1. The pulse starts 5 minutes before.
2. Cyan is the scheduler's colour.
3. The default pirate watch runs Friday and Saturday 19:00–02:00 local over 6900–7000 kHz, and starts switched off.
4. The radio is restored to how it was after each run.
5. An owner change mid-run ends that run, and the scheduler doesn't take the radio back.
6. The noise floor is measured on quiet spots beside the frequency, and the squelch is set 8 dB above it.
7. A broadcast's window runs 1 minute early to 2 minutes late.
8. With several frequencies, the strongest is picked in the first 30 s, with no switching afterwards.
9. On overlaps, a broadcast beats a watch, and otherwise the one already running wins.
10. The religious rule is a denylist plus keywords, with an allowlist. WRMI and WBCQ are kept, and WWCR, WTWW and WINB are hidden.
11. Translation is on by default for any auto-detected transcript.
12. Agents manage agent-added schedules only, and can't change the master switch.
13. A watch confirms candidates with Signal ID and only records voice-like signals.
14. A broadcast is one file, closing early only after 10 minutes of quiet. A watch makes a file per transmission.
15. Schedules always use the RSP, switching away from Demo or an IQ file and back.
16. Timetable schedules follow the timetable: they update when it changes, and switch off when the broadcast is gone.
17. A run started early from the ticker isn't muted.

## Left to the builder

- The exact spectrum thresholds for a pirate candidate, beyond the 10 dB, 3 s and wider-than-a-carrier rules.
- How the Schedules window looks, within the description above.
- The translation model and prompt, within the untrusted-data rules.
- How the ticker scrolls, and how it collapses on a narrow window.
- How the timetable is indexed for search.
