# MCP server: design

**Status:** draft for approval, 2026-10-31
**Modelled on:** Cadjitsu's MCP server (RidgebackZulu/cadjitsu, `src/app/mcp/`, `plugins/cadjitsu/`)

## Why

The owner wants AI agents (Claude Code, Hermes and others) to run SubFloor for them. Typical requests:

- "What type of signal is my cursor on?"
- "Research a broadcast, then at its time tune, record, and set the squelch above the noise floor."
- "Generate a map of the FT8 talkers."
- "Look up the callsign…"
- "Research pirate stations, hunt the band for audio, and record only real pirates, not noise."
- "Research propaganda stations and their schedules."
- "Scan 4–7 MHz for digital signals, identify each one's modulation, and log them as bookmarks."

The agent does the research and the reasoning. SubFloor gives it hands (tune, record, bookmark) and eyes and
ears (spectrum, levels, decodes, transcripts). This job builds the server, the button, the setup window and the
tools for what SubFloor can already do. The later jobs add their own tools:

- **Signal ID:** what a signal is, with its bandwidth, shift and baud.
- **Noise floor and C/N markers:** a measured noise floor, so the squelch can sit above it.
- **Scheduler:** jobs that run at a set time with no agent present.

## Goals

- **Off until switched on.** It answers only this Mac (127.0.0.1) and only requests carrying its token.
- **Easy setup.** Switch it on, pick your agent from a list, and copy one prepared snippet (or click one
  button). The snippet has the URL and token filled in.
- **A glowing MCP button in the main window's top bar.** Its colour shows the server's state (below), it
  pulses once per agent request, and its tooltip names the agent.
- **An event log** of every connection, tool call, result and refused request, also written to a small
  rolling file.
- **A plugin and skill** for Claude Code and Hermes. The skill teaches an agent to work the radio well: when
  HamItUp is needed, checking signal against noise before recording, hunting, and logging.
- **Agents never collide.** The default port is **7824** (Cadjitsu uses 7823), and the port can be
  changed.

## Non-goals

- Reaching SubFloor from other machines, or through a cloud connector.
- Transmitting. SubFloor is receive-only.
- Deleting recordings, or deleting or overwriting bookmarks the owner made.
- Per-tool permission switches. The log shows everything an agent does, and the owner can switch the server
  off.
- Streaming results (server-sent events). Each request gets one plain JSON reply, as in Cadjitsu.

## Anti-goals (failures even if it "works")

- **The server comes up on its own** on an old token or a wider address.
- **An agent fills the disk.** For example, a recording left running for hours. Every recording an agent
  starts has a time limit.
- **The button animates constantly.** It only glows steadily, pulsing once per request (Cadjitsu's rules,
  at no more than 30 frames a second).
- **A tool call freezes the window.** Tools that wait (listening, recording a clip) must not block the
  main thread.

## Protocol and server (as Cadjitsu)

- **Transport:** MCP "Streamable HTTP". JSON-RPC 2.0 is sent as `POST /mcp`, and every reply is plain
  `application/json` (a batch reply is an array). A notification gets `202` with no body, and `DELETE /mcp`
  ends a session.
- **Rejected requests:** a wrong path gets 404, a wrong method 405 with `Allow: POST, DELETE`, a body over
  16 MB 413, and headers over 64 KB 431.
- **Protocol versions:** it offers 2025-06-18, 2025-03-26 and 2024-11-05, replying with the one the client
  asks for if it knows it, else the newest.
- **Initialize reply:** includes `serverInfo` (`subfloor`, "SubFloor SDR", the app version) and
  `instructions` (a short how-to: units are Hz, display frequencies, HamItUp, start with `get_status`).
- **Auth:**
  - Every request needs `Authorization: Bearer <token>`.
  - The token is 32 random bytes in base64url (43 characters), compared in constant time.
  - It is kept in the Keychain (service `app.subfloor.SubFloor.mcp`), like the OpenRouter key.
  - A missing or wrong token gets 401 with `WWW-Authenticate: Bearer realm="subfloor"` and an "Auth" log
    line.
- **Origin:** a request with an `Origin` header other than localhost or 127.0.0.1 (http or https, any port),
  `[::1]`, or `null` gets 403. This stops a web page in a browser reaching the server.
- **Listening:** on 127.0.0.1 only, using Network.framework (`NWListener`), with no new dependencies.
- **Port:**
  - Default 7824, changeable from 1024 to 65535.
  - If the port is taken, the server stays off and says why in the setup window and the log, and the
    button stays grey with a ⚠︎.
- **Sessions:**
  - `initialize` creates a session (a UUID returned in `Mcp-Session-Id`) and records the client's name and
    version, for example "claude-code 2.1".
  - An unknown session id (from before a restart) or a tool call without one counts as a live session, so
    the button shows the agent is there.
  - "Connected" means some session was active in the last 300 s.
- **Handling:**
  - Tool bodies run on the main actor, since they act on `AppModel` like the user does.
  - Tools that change the radio (tuning, recording, squelch, decoder, bookmarks) run one at a time, in order.
    Read-only tools (status, cursor, spectrum, lists, decodes, transcripts) and pings answer at once, even
    while another agent's `listen` is waiting.
  - A tool that waits (`listen`) is `async` and awaits without blocking the main thread.
  - **The owner always wins.** If the owner, or another agent, retunes, stops the radio or changes the mode
    while a `listen` is waiting, it stops early and says so ("interrupted: retuned to 7.200 MHz by the
    owner"). It doesn't return levels from a frequency the agent didn't ask for.
- **Settings:** enabled, port, and a log of the last 1,000 events in memory. The log file is
  `~/Library/Logs/SubFloor/mcp.log`, one JSON object per line, never over 1 MB (the oldest lines are
  dropped).
- **Start-up:** if the owner left the server on, it starts with the app. If the port is busy it stays off
  and warns.

## The MCP button

A pill reading **MCP** in the top bar, right after the Dial chip, the same size as the Device and Dial chips.

| State | Look | Tooltip |
| --- | --- | --- |
| Off | grey outline, grey dot | "MCP server off: click to let AI agents use SubFloor" |
| Off, port busy | grey with an orange ⚠︎ | "MCP server could not start: port 7824 is in use" |
| Listening | blue outline and dot | "MCP server listening, no agent connected" |
| Connected | green, with a steady soft glow around the pill and a glowing dot | "Claude Code 2.1 connected" |

Each handled request makes the glow pulse once, coalesced so a burst is a single pulse. Clicking the button
opens the MCP window.

## The MCP window (Radio › MCP Server…, or the button)

**Setup tab**

- **Enable the MCP server**, plus Port (Apply) and Status. The status line is one of:
  - "● Off"
  - "● Listening on http://127.0.0.1:7824/mcp — no agent connected"
  - "● Connected — Claude Code 2.1"
  - "● Could not start: port in use"
- **Token:** hidden until **Show**, with **Copy** and **New Token**. A new token disconnects existing agents,
  after confirmation.
- **Connect an agent:**
  - A list of common agents. Choosing one shows its ready-to-paste snippet with the URL and token filled in,
    a **Copy** button, and one line on where it goes.
  - Agents with a command-line tool installed on this Mac also get an **Add to <agent>** button, which runs
    that tool's own "add MCP server" command and shows its output. It is disabled when the tool isn't found.
  - The list is pre-populated with:
    - **Claude Code**, CLI and one click: `claude mcp add --transport http subfloor <url> --header "Authorization: Bearer <token>"`
    - **Claude Code plugin**: install from GitHub, and set the `SUBFLOOR_MCP_TOKEN` (and `SUBFLOOR_MCP_URL`)
      environment variables.
    - **Claude Desktop**: `claude_desktop_config.json` using `npx mcp-remote <url> --header …`. Claude
      Desktop's own connectors can't reach a local server, and this needs Node.
    - **Hermes Agent**, CLI and one click: `hermes mcp add subfloor --url <url> --auth header`, plus the
      plugin install for the skill. A second entry gives the `~/.hermes/config.yaml` block.
    - **OpenAI Codex CLI**, CLI and one click: `~/.codex/config.toml` `[mcp_servers.subfloor]` with `url`
      and the token, or `codex mcp add …`.
    - **Gemini CLI**: `~/.gemini/settings.json` `mcpServers.subfloor` with `httpUrl` and `headers`.
    - **Cursor**: `~/.cursor/mcp.json` with `url` and `headers`.
    - **VS Code (Copilot)**: `.vscode/mcp.json` `servers.subfloor`, type `http`, with `url` and `headers`.
    - **Windsurf**: `mcp_config.json` with `serverUrl` and `headers`.
    - **LM Studio**: `mcp.json` with `url` and `headers`.
    - **Goose**: an extension of type `streamable_http` with a uri and headers.
    - **Any other client**: URL plus header.
  - Each snippet's exact format is checked against that agent's current documentation when it is built,
    and is unit-tested for the URL, port and token being filled in.
- A line about the **SubFloor skill**: how to install the plugin in Claude Code and Hermes.

**Event log tab:** time, event (Server / Connected / Disconnected / Tool call / Result / Error / Refused),
client, and a one-line summary. Selecting a row shows the arguments and result, shortened. The tab has a
filter field, **Clear view**, and **Open log folder**.

## Tools in this job

All frequencies are display Hz, the frequency the listener means. Every tool also accepts a frequency as a
string ("7.074 MHz", "7074k", "6925"), using the existing `FrequencyParser`. Results are JSON text, with
`structuredContent` for clients on 2025-06-18. A failed precondition, such as the radio being stopped, comes
back as a tool error that says what to do: "The radio is stopped: call `start_radio` first."

| Tool | What it does |
| --- | --- |
| `get_status` | Radio state in one call: running/source/device; VFO, capture centre and span; mode and bandwidth; HamItUp on and its LO; squelch on, level, and signal level now (dBFS); recording and Auto state; decoder mode; transcription on and its key present; MCP clients. |
| `start_radio` / `stop_radio` | Run or stop the receiver. |
| `tune` | `frequency`, plus optional `mode`, `bandwidth_hz` and `hamitup` (`"on"`, `"off"` or `"auto"`). `auto` turns HamItUp on below 30 MHz when an upconverter is set up, and leaves it otherwise. Returns the tuning in effect, clamped to what the RSP1B and HamItUp can reach. |
| `set_squelch` | `enabled`, `level_dbfs`. |
| `get_cursor` | What the owner is pointing at, as three cursors: the **mouse** (where the pointer last rested on the spectrum, kept after it leaves, with how long ago), the **decoder cursor** (the amber one placed with a right click), and the **VFO**. For each it gives the frequency, the level there, the nearest bookmark and any decodes near it. The Signal ID job adds the signal's type to each. |
| `get_spectrum` | Power across `from_hz…to_hz`, or the current view, from the live averaged spectrum. Returns up to `points` (default 512) max-held values plus a peak list (frequency, level, width at −6 dB). The capture span is the limit; outside it, the tool says to tune there first. |
| `listen` | Stays tuned for `seconds` (2–60, default 15), then reports signal level statistics (min, median, max), how long the squelch was open, and a Whisper transcript with SubFloor's voice / possible noise verdict. The transcript is made only when the owner has **Transcribe Recordings** on and a key saved; `transcribe: false` skips it. It costs about $0.0001 per 15 s. Nothing is kept unless `keep: true`, which saves the clip as a recording. |
| `start_recording` | `kind` (`audio`, `iq` or `both`) and `max_minutes`: default 30, maximum 240, after which it stops itself. |
| `stop_recording` | Stops the recording. |
| `set_auto_record` | Turns Auto on for `minutes` (default 60, maximum 720), after which SubFloor turns it off again, or turns it off. It needs the squelch on, and says so if it isn't. Auto the owner turned on by hand has no limit. |
| `list_recordings` | Filter by `since`, `until`, `frequency` (± `tolerance_hz`), `voice_only` and `limit`. Returns file, start, length, frequency, mode, Auto or not, heard, and the transcript verdict. |
| `get_transcript` | One recording's text, with word times. |
| `search_transcripts` | The same search as the Recordings window: matching recordings and snippets. |
| `list_bookmarks` | Optional `query` and `group`. |
| `add_bookmark` | Name, frequency, mode, bandwidth, group, notes, HamItUp. It is marked as added by the calling agent. |
| `update_bookmark` | Changes a bookmark an agent added (any agent, so one can tidy up after another). On the owner's own bookmarks it may only add to the notes. |
| `delete_bookmark` | Only bookmarks an agent added. |
| `set_decoder` | `ft8`, `wspr`, `cw`, `psk31`, `rtty` or `off`, decoding inside the passband as the decoder panel does. |
| `get_decodes` | Slot decodes (FT8/WSPR) and live rows (CW/PSK31) since a time. FT8 and WSPR come parsed: callsigns, grid, latitude and longitude, SNR, frequency and time. |
| `get_ft8_stations` | Every station heard in the last `hours` (default 24, maximum 168): callsign, grid, position, best SNR, last heard, band and count. This is the map's data; the agent draws the map. |

**Decode history (new).** Today FT8 and WSPR decodes live only in the panel's last 200 rows. This job keeps
them as well:

- **Where:** a day file under `~/Library/Application Support/SubFloor/decodes/<UTC day>.jsonl`, one parsed
  decode per line.
- **How long:** 30 days.
- **What the parser understands:** the standard FT8 and WSPR message shapes (CQ, a call pair with a grid,
  reports, RR73, 73). A message it can't parse is kept as text only.
- **Positions:** a Maidenhead grid becomes the centre of the square's latitude and longitude.

## The plugin and skill

The plugin lives in `plugins/subfloor/`, with a marketplace file at the repo root, as in Cadjitsu:

- **`.claude-plugin/plugin.json` and `plugin.json`:** both a Claude Code plugin and a Hermes agent plugin.
- **`.mcp.json`:** `${SUBFLOOR_MCP_URL:-http://127.0.0.1:7824/mcp}` with `Bearer ${SUBFLOOR_MCP_TOKEN}`.
- **`skills/subfloor-radio/SKILL.md`:** how to drive SubFloor well, plus `references/tools.md`. The skill covers:
  - **First call:** start with `get_status`.
  - **HamItUp:** frequencies are display frequencies; HamItUp is for HF if it is fitted.
  - **Squelch:** before recording, use `listen` to compare signal with noise, then set the squelch a few dB
    above the noise.
  - **Pirate hunts:** step through the usual pirate frequencies, `listen` with transcription, and keep only
    voice or music.
  - **Bookmarks:** log with a clear name, the group, and notes giving what, when and the evidence.
  - **Callsigns:** look them up on the web.
  - **Recording limits:** never leave a recording running unbounded.

## Where the code goes

- **`Sources/SubFloor/MCP/`:**
  - `MCPHTTP.swift`: request parsing and replies, pure, unit-tested.
  - `MCPServer.swift`: `NWListener`, sessions and state.
  - `MCPRPC.swift`: the JSON-RPC dispatch, pure.
  - `MCPTools.swift`: the registry, schemas and the tools over `AppModel`.
  - `MCPLog.swift`.
  - `MCPSettings.swift`: the Keychain token, port and enabled flag.
  - `AgentSnippets.swift`.
- **Decode parsing and history:** `Sources/Modems/Framework/` (the parser) and `Sources/Recording/` or a new
  file for the day log. JSON uses `JSONValue` from the Transcription target.
- **UI:** `Sources/SubFloor/UI/MCP/MCPButton.swift` and `MCPWindow.swift`, with a `Window` declared in
  `SubFloorApp.swift`.
- **The server lives as long as the app.** It is held by the app delegate. It starts, if enabled, once the
  model is attached when the main window appears, which is after `applicationDidFinishLaunching`. It stops
  on quit.

## Testing

- **Unit tests:**
  - HTTP parsing, including keep-alive, partial bodies and limits.
  - Auth: missing, wrong and right tokens, in constant time.
  - Origin rules.
  - JSON-RPC: initialize and version choice, ping, tools/list, a tools/call error, batches, notifications
    getting 202.
  - Session and connected-state timing.
  - Each tool against a model running the demo source.
  - The FT8/WSPR message parser and grid-to-position conversion.
  - Snippets filled in correctly.
- **An integration test** with real HTTP over loopback, on an ephemeral port.
- **End to end, by hand on this Mac:**
  - Claude Code, Hermes and Codex (all installed) each connect, list tools, and run `get_status` and
    `tune` against a demo-source instance on another port.
  - The button is checked in each state.

## Calls made in review (the designer's, open to change)

- **The mouse cursor is remembered.** `get_cursor` reports where the mouse last rested on the spectrum,
  because the owner asks from another window.
- **Auto has a time limit.** Auto switched on by an agent turns itself off after its `minutes`.
- **`listen` follows the Transcribe Recordings switch.**
- **The owner wins conflicts.** Read-only tools never wait behind a `listen`.
- **Agents share agent bookmarks.** Any agent may edit or delete bookmarks any agent added; the owner's are
  protected apart from appending notes.

## Left to the builder

- Exact layout and spacing of the button and window, within the descriptions above.
- The tool result shapes beyond the fields named.
- How `listen` captures its clip, whether from the audio recorder's pre-roll or a short in-memory tap.
