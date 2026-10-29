# Speech transcripts for recordings — design

Date: 2026-10-29. Status: owner said "build it" after the playback below; the calls marked *(my call)* are the builder's defaults and the owner can override any of them.

## Why

The owner runs Auto with a low squelch on HF (11.175 MHz USB and the like) so weak voices aren't missed. The cost: most Auto recordings are just noise. Today the owner steps through them one by one by ear, and the majority have nobody talking. Raising the squelch would cut the noise but lose weak voices, and those are exactly the recordings they want.

The feature sends each recording to a speech-to-text model. A recording with real words gets a green mark and its words; one without gets marked as possible noise. The owner can then go straight to the recordings with someone talking, and can search everything ever said.

## Goals

1. **Every new audio recording is transcribed** once it closes, when the feature is on, using a speech-to-text model on OpenRouter.ai.
2. **Each recording gets one of two verdicts:**
   - **Voice:** the transcript has real words. It gets a small **green marker** in the Recordings timeline.
   - **Possible noise:** no usable words came back (noise, or speech too weak to transcribe). It gets a grey marker.
3. **Nothing is ever deleted.** The owner said a weak voice wrongly marked "possible noise" is acceptable, but deleting it is not. The verdict is only a label.
4. **A toggle turns it off.** The owner records digital modes sometimes and doesn't want those sent off or labelled.
5. **Words under the waveform.** Clicking a recording in the Recordings window shows its words under the player's waveform, each word at the time it was spoken, so they line up with the signal.
6. **Global search.** A search field in the Recordings window header. As you type, every recording whose transcript doesn't contain the text fades out. Clearing the field brings everything back.

## Non-goals

- No change to how Auto decides to record (squelch, trigger, gaps). Transcription runs after a recording is finished and never affects capture.
- No live (while-receiving) transcription.
- No on-device speech model. The owner chose OpenRouter.
- No deletion, no auto-cleanup, no hiding recordings by default.
- No editing of transcripts.
- IQ recordings are not transcribed (they aren't audio and aren't in the Recordings window).

## Anti-goals (would make this a failure even if it works)

- Any path that deletes or modifies a recording file.
- The API key showing up in a log, a crash report, the session JSON, a git commit, or on screen in clear text.
- Transcription work making the radio stutter. It must never touch the DSP or audio threads.
- A network outage or a rejected key making the app nag. Failures are quiet, visible on demand, and retryable.
- Whisper's well-known invented text ("Thank you for watching", "*car engine noise*") showing up as a green "voice" recording.

## What the owner decided

- OpenRouter.ai as the provider. The key lives in the repo-root `.env` today as `OPENROUTER=<key>`.
- Mark, don't delete.
- Toggleable.
- Green marker for a good transcript.
- Word-timed text under the waveform when a recording is clicked.
- A search bar that fades non-matching recordings live, and restores all when cleared.

## Findings that shape the design (measured 2026-10-29)

**The API**
- Endpoint: `POST https://openrouter.ai/api/v1/audio/transcriptions`.
- JSON body:
  ```
  {"model", "input_audio": {"data": <raw base64>, "format": "wav"|"flac"|…},
   "response_format": "verbose_json",
   "timestamp_granularities": ["word","segment"],
   "language": "en"}
  ```
- Header: `Authorization: Bearer <key>`.
- Limits:
  - 25 MB per request.
  - Upstream providers time out after about 60 s of processing.

**Whisper Large V3** (`openai/whisper-large-v3`, $0.000008/s, about 3 cents per hour of audio)
- It returns:
  - `text`;
  - `words[]` of `{word, start, end}` in seconds, file-relative;
  - `segments[]` with `start`, `end`, `text`, `avg_logprob`, `no_speech_prob` and `compression_ratio`;
  - `usage.cost`.

**What came back for the owner's real recordings**

| Clip | What Whisper returned | Signals |
|---|---|---|
| Voice clip (32 s) | The whole exchange ("Last caller, last caller, this is Dustmob…"), 46 timed words | Segments `avg_logprob` ≈ −0.55. It then invented a trailing "I'm sorry." with `avg_logprob` −1.17. |
| `SubFloor_20261028_140122Z_11175000Hz_USB` | "This is the clock… Dustmaw… Standing by for traffic." | Segments −0.41…−0.56 |
| Pure noise | `"."` | −1.65 |
| Pure noise | `"*car engine noise*"`, twice | −1.20 / −1.26 |
| Pure noise | Empty | `no_speech_prob` 1.0, no words |
| `SubFloor_20261027_200017Z_11175000Hz_USB` (borderline) | Short scraps: "I see." −0.52, "This is" −0.25, "All right." −0.29, "AutoGland" −1.25, "..." −1.16, "*Humming*" −1.12, "Monogram." −0.26, "Now." −0.76 | Mixed |

These JSON responses are saved as test fixtures. They contain no secrets. Each is named after its recording, and the 32 s voice clip is `voice-clip-32s.json`. They live in `Tests/TranscriptionTests/Fixtures/`.

## How it works

### 1. Pipeline (per recording)

1. **Trigger.** When AppModel logs a finished `.recording` entry (`AppModel.appendToLog` → `library.didLog`), and transcription is on, a key is set, and the file is an audio recording, the file is queued.
   - *(My call)* This covers both Auto and manual recordings. Manual recordings are deliberate and benefit from search too, and the cost is negligible.
2. **Prepare the audio** (off the main actor):
   - Read the file (FLAC, ALAC or WAV, 48 kHz mono).
   - Downsample to 16 kHz mono 16-bit PCM WAV in memory, which is about 32 KB/s.
   - Split recordings longer than 120 s into chunks of at most 120 s. Each cut goes at the quietest 100 ms window in the last 15 s before the limit, so no word is split.
   - Each chunk is sent separately. Word and segment times are shifted by the chunk's start offset.
   - A file that is entirely digital silence (all zeros) is labelled possible noise without being sent.
3. **Send** to OpenRouter.
   - One request per chunk.
   - Request timeout: 90 s.
   - At most 2 recordings in flight *(my call)*.
4. **Classify** (pure function, see below), then **store** the result.
5. **Update the UI.** The timeline marker appears and the search index is updated.

### 2. Classifier (the guard against invented text)

A segment is **dropped** if any of these hold:
- `no_speech_prob > 0.6`;
- `avg_logprob < −1.0`;
- `compression_ratio > 2.4` (Whisper's repetition loops);
- its text, after trimming spaces and punctuation, is empty;
- it is entirely a sound annotation: wrapped in `*…*`, `[…]` or `(…)`, or containing only such annotations and punctuation;
- it is, case-insensitively and ignoring punctuation, one of Whisper's stock silence phrases: "thank you", "thanks for watching", "thank you for watching", "thank you so much for watching", "please subscribe", "subtitles by the amara.org community", "you", "bye".

**Words** are kept only if their midpoint falls inside a kept segment. Words that are only punctuation or an annotation are dropped.

**Verdict.** **Voice** when there are at least 3 kept words; otherwise **possible noise**. These thresholds are *(my call)*, chosen against the table above:
- The voice clips are Voice, and "I'm sorry." is dropped.
- All four noise clips are possible noise.
- The borderline clip is Voice with 9 words ("I see. This is All right. Hi. Monogram. Now."). This was checked by running these exact rules over the saved responses.

The thresholds live in one place as named constants.

The full raw response is kept, so a later change to the classifier can re-run over stored transcripts without paying for them again. The classifier is applied when a transcript is loaded, not baked into the stored verdict.

### 3. Storage

- Sidecar file: `<recordings folder>/.subfloor/transcripts/<recording file name>.json`. It sits next to the existing `peaks/` cache.
- Contents:
  ```
  { "version": 1, "file", "model", "language", "createdAt", "durationSeconds", "costUSD",
    "chunks": [{ "offsetSeconds", "response": <raw verbose_json> }] }
  ```
- **Failures are not written to disk** *(my call)*. The queue remembers them in memory. A recording with no sidecar is "not transcribed".
- **What a relaunch picks up** *(my call)*: at launch, and whenever the feature is turned on, the queue adds audio recordings that meet all of these:
  - no sidecar;
  - a `.recording` log entry whose start is within the last 24 hours;
  - started after `TranscriptionSettings.enabledSince`. This is the time the feature was last switched on, saved in settings.

  That retries recent failures and recordings made while the app was offline. It never quietly spends money on the older backlog, which only the **Transcribe older recordings** button queues.
- Sidecars are written atomically (write to a temp file, then rename), the same way as other writes.
- If a recording file disappears, its sidecar is ignored. Cleaning up orphans is out of scope.
- **The index.** On library reload, all sidecars are loaded off the main actor into an in-memory index of `file → (verdict, kept words, normalized text)`. 237 recordings is small. The index updates when a new transcript lands.

### 4. Failures and retries

- **Network errors, 5xx and 429:** retry the recording up to 3 times, after 10 s, 60 s and 5 min. After that it is marked **failed** in memory and gets a small orange marker. It is retried on the next launch, or when the owner picks *Transcribe* on it.
- **401 or 403 (bad key):**
  - Stop the whole queue.
  - Show "OpenRouter rejected the key" in the Transcription settings and next to the Recordings header chip.
  - Don't retry until the key changes.
- **402 (out of credit):** same as a rejected key, with the message "OpenRouter account is out of credit".
- **400 (bad request, for example an unsupported format):** mark failed and don't retry automatically. One example is a model that rejects `timestamp_granularities`. The response's error message becomes the failure reason.
- **A different model** *(my call)*. The model field is free text. If a response lacks `avg_logprob`, `no_speech_prob` or `compression_ratio`, those checks are skipped for that segment, and the annotation, stock-phrase and 3-word rules still apply. If it lacks `words[]`, each kept segment's text is spread evenly across that segment's time span as pseudo-words, so the strip and search still work.
- **Very short recordings** *(my call)*. A recording under 0.5 s is labelled possible noise locally without being sent.
- **Folder changes mid-job.** The job writes its sidecar next to the recording it was given. The result goes into the index only if that folder is still the current one.
- Nothing ever pops up a dialog on its own.

### 5. The API key

- It is stored in the macOS Keychain as a generic password, service `app.subfloor.SubFloor.openrouter`. It is never stored in `SessionState`, UserDefaults or logs.
- **Settings → Transcription section:**
  - a SecureField for the key, with Save and Remove;
  - an **Import from .env…** button. It opens a file picker; the app reads the line `OPENROUTER=` (or `OPENROUTER_API_KEY=`), strips quotes, and saves to the Keychain. The owner points it at the repo's `.env` once.
  - It shows only whether a key is set ("Key saved ✓"), never the key.
- The key is read from the Keychain once at launch and kept in memory. Locally built (ad-hoc signed) copies get a new code signature on every build, so macOS asks once per build whether SubFloor may use the key. "Always Allow" covers that build. The Developer ID release builds don't re-ask. This is accepted *(my call)*.
- Code reaches the key through a small `APIKeyStore` protocol. Tests use an in-memory store and never touch the real Keychain.
- `.env` is added to `.gitignore`. Today it isn't ignored, so a stray `git add -A` would commit the key.

### 6. Settings and the toggle

New `TranscriptionSettings` in `SessionState`, decoded with `decodeIfPresent` like every other field:
- `enabled`: default **on** once a key exists *(my call)*. The owner asked for this; with no key it does nothing.
- `enabledSince: Date?`: set each time `enabled` goes from off to on, and on first launch with the feature. It is used by the relaunch rule in §3.
- `model`: default `openai/whisper-large-v3`, an editable text field.
- `language`: default `en`, with a picker offering English or Auto-detect *(my call)*. Auto-detect on noise tends to invent other languages.

Settings → Transcription section, in this order:
1. On/off.
2. Key controls.
3. Model.
4. Language.
5. A one-line privacy note: "Recordings are sent to OpenRouter and the model's provider for transcription."
6. **Transcribe older recordings**: a button showing how many audio recordings in the folder have no transcript and the estimated cost, for example "Transcribe 237 recordings (≈ $0.05)". It queues them, newest first. While running it shows progress and a Stop button. Cost estimate: total seconds × the model's per-second price for the default model; otherwise just the count.

The toggle is also available:
- as a menu item, **Transcribe Recordings**, next to the Auto-record items, with a checkmark;
- as a small chip in the Recordings window header, so it is quick to flip before a digital-mode session.

Turning it off stops new recordings from being queued. Jobs already in flight finish; queued ones are dropped.

### 7. Recordings timeline markers

These are drawn in `MarkerPaint.draw`. The state comes in via `TimelineLayout` so the Equatable check stays correct.
- **Voice:** a small green dot (`RecordingsTheme` green 0x4ddb78) at the pill's **trailing** top edge, mirroring the existing unheard dot at the leading edge.
- **Possible noise:** a small hollow grey ring in the same spot. The pill itself is not dimmed *(my call)*. Dimming is reserved for search.
- **Failed:** a small orange dot. Hovering shows the reason.
- **Queued or in flight:** nothing *(my call)*. It's usually only seconds.
- Not transcribed (feature off, or older recordings): nothing.
- **Context menu on a marker:** *Transcribe* (or *Transcribe again*), which re-queues that one recording.

### 8. Words under the waveform

A new view, `TranscriptStrip`, sits between `PlayerWaveform` and `PlayerControls` in `PlayerPanel`.
- **Same time axis as the waveform.** It uses the waveform's `WaveformZoom.visibleRange(duration:playhead:)`, so words line up at every zoom level and follow the playhead the way the waveform does.
- **Layout:**
  - Two lines tall.
  - Each kept word is drawn starting at the x of its `start` time.
  - If a word would overlap the previous word on line 1, it goes on line 2. If it would overlap there too, it is hidden. Zooming in reveals hidden words.
  - A word whose `start` is off-screen isn't drawn.
- **The word under the playhead** (`start ≤ position < end`) is drawn in the primary colour; the others are secondary.
- **Words matching the current search** are highlighted (green background).
- Clicking a word seeks the player to its `start`.
- **No words to show:**
  - possible noise: a one-line message, "Possible noise — no clear speech";
  - failed: "Couldn't transcribe — <reason>";
  - in flight: "Transcribing…";
  - not transcribed: "Not transcribed", with a *Transcribe* button.
- Hovering the strip shows the full kept text as a tooltip.
- VoiceOver reads the strip as the full kept text.

### 9. Search

- A search field goes in the Recordings window header, on the right, before Show in Finder. ⌘F focuses it.
- **Matching:**
  - Case- and diacritic-insensitive.
  - The query is split into terms on spaces, and every term must appear as a substring of the recording's kept text (AND). So "dust traffic" matches "Dustmaw… standing by for traffic".
  - Callsign-style terms work naturally, since they are substrings.
- **The timeline** fades every marker whose recording doesn't match to 0.2 opacity, live on every keystroke. Recordings without a transcript also fade, because they don't contain the text.
- **Global across days:**
  - The header shows "N matches", counted across all days. Only recordings the catalog lists count; sidecars of deleted files are ignored.
  - ◀ ▶ buttons jump to the previous or next matching recording in time. They switch the day if needed and select the recording, which loads the player and shows its words with the matches highlighted.
  - Return is the same as ▶.
- Clearing the field (or Esc) restores every marker to normal.
- The search text is not persisted *(my call)*.

## Code layout (follows the existing structure)

- New target **`Transcription`**, depending on Foundation and AVFoundation only, with no new packages. It holds:
  - the request and response models;
  - `OpenRouterTranscriber` (URLSession behind an injectable transport protocol, so tests never hit the network);
  - the audio prep (decode, downsample, chunk, WAV encode);
  - `TranscriptClassifier`;
  - `TranscriptStore` (sidecar read and write) and the search matcher.
- In the app (`Sources/SubFloor/`):
  - `KeychainKey`, a small wrapper;
  - `TranscriptionQueue`, `@MainActor @Observable`, which owns the jobs, retries and status;
  - the wiring in `AppModel` and `RecordingsLibrary`;
  - settings UI, the menu item, timeline markers, `TranscriptStrip`, and the search UI.
- Tests:
  - `Tests/TranscriptionTests`, using the saved real responses as fixtures;
  - app-level tests in `Tests/SubFloorTests`.
  - No test may make a network call.

## Left to the builder

- Exact view sizes and spacing.
- Exact names of internal types beyond those above.
- Whether audio prep streams or reads whole files (recordings are minutes long at most).
- Wording of tooltips and accessibility labels, in the same voice as the existing UI.
