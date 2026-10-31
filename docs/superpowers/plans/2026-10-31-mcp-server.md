# MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AI agents on this Mac can drive SubFloor through a local MCP server, shown by a glowing MCP button, set up from a window with ready-made snippets for common agents.

**Architecture:** A Network.framework listener on 127.0.0.1 hands each HTTP request to `MCPRPC` on the main actor. `MCPRPC` checks the origin and token, speaks JSON-RPC (MCP Streamable HTTP, with plain JSON replies), and calls a tool provider. Tools act on `AppModel` the way the UI does. Tools that change the radio run one at a time; read-only tools answer at once. FT8 and WSPR decodes are parsed and kept in day files so the tools can answer for past hours.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI/AppKit, Network.framework, Security (Keychain), Swift Testing. No new package dependencies.

**Spec:** `docs/superpowers/specs/2026-10-31-mcp-server-design.md`

## Global Constraints

- **Platform:** macOS 15, swift-tools 6.0, no new package dependencies (Package.swift's dependency list stays empty).
- **Address and port:** listen on 127.0.0.1 only. The default port is **7824**, allowed 1024–65535.
- **Endpoint:** `POST /mcp` and `DELETE /mcp`. Replies are `application/json` and never SSE.
- **Limits:** body 16 MiB (413), headers 64 KiB (431), wrong path 404, other methods 405 with
  `Allow: POST, DELETE`.
- **Protocol versions:** `["2025-06-18", "2025-03-26", "2024-11-05"]`. Reply with the one the client asks for
  if it is known, else the first.
- **serverInfo:** `{name: "subfloor", title: "SubFloor SDR", version: <CFBundleShortVersionString or "dev">}`.
- **Token:**
  - 32 random bytes (`SecRandomCopyBytes`), base64url with no padding, so 43 characters. Compared in
    constant time.
  - Kept in the Keychain: service `app.subfloor.SubFloor.mcp`, account `token`.
  - A missing or wrong token gets 401 with `WWW-Authenticate: Bearer realm="subfloor"`.
- **Origin:** allowed when absent, `null`, or http/https `localhost`, `127.0.0.1` or `[::1]` with any port.
  Anything else gets 403.
- **Connected:** some session active within the last **300 s**.
- **Settings:** UserDefaults key `mcp` holds JSON `{enabled: false, port: 7824}`. The server is off by default.
- **Log:**
  - `~/Library/Logs/SubFloor/mcp.log`, JSON lines, at most **1 MiB** (the oldest lines are dropped).
  - The newest **1,000** events are kept in memory.
- **Display frequencies:** all frequencies in tools are display Hz. Any frequency argument also accepts a
  string, parsed by `FrequencyParser.parse`.
- **Time limits:**
  - `listen`: 2–60 s, default 15.
  - `start_recording`: `max_minutes` default 30, maximum 240.
  - `set_auto_record`: `minutes` default 60, maximum 720.
  - `get_ft8_stations`: `hours` default 24, maximum 168.
- **Decode history:** `~/Library/Application Support/SubFloor/decodes/<yyyy-MM-dd UTC>.jsonl`, kept 30 days.
- **Agent bookmarks:** `Bookmark.addedBy` = the client name. Agents may edit or delete agent-added bookmarks.
  On the owner's bookmarks they may only append to the notes.
- **Copy:** the user-facing strings in the spec are exact: the button tooltips and the status lines.
- **Plugin:** `plugins/subfloor/`, with env vars `SUBFLOOR_MCP_URL` and `SUBFLOOR_MCP_TOKEN`.

## Review Focus

1. **A request split across TCP reads, or two requests on one keep-alive connection.** Both are parsed and
   answered in order. Pinned in Task 3: `parsesSplitAndPipelinedRequests`.
2. **Port 7824 already taken** (Cadjitsu moved, or a second SubFloor). The server state becomes
   `.failed("Port 7824 is in use")`, the button is grey with ⚠︎, and nothing crashes. Pinned in Task 4:
   `busyPortFailsCleanly`.
3. **A new token while an agent is connected.** The next call gets 401 and is logged as Refused. Pinned in
   Task 4: `newTokenRefusesTheOldOne`.
4. **Bad frequency input** ("abc", negative, 5 GHz). A tool error that names the range; the radio isn't
   retuned. Pinned in Task 5: `tuneRejectsUnreachableFrequencies`.
5. **The owner retunes or stops the radio during `listen`.** It returns early with "interrupted"; with the
   server switched off mid-listen, the reply is still sent or the connection closed, with no crash. Pinned
   in Task 6: `listenStopsWhenTheOwnerRetunes`.

---

### Task 1: FT8/WSPR message parser and Maidenhead grids

**Files:**
- Create: `Sources/Modems/Framework/SlotMessage.swift`
- Test: `Tests/ModemsTests/SlotMessageTests.swift`

**Interfaces:**
- Produces:
  - `public struct SlotMessage: Equatable, Sendable { public var kind: Kind; public var to: String?; public var from: String?; public var grid: String?; public var report: String? }`
  - `public enum Kind: String, Sendable { case cq, call, report, rogerReport, rr73, rrr, seventyThree, wspr, other }`
  - `public static func parse(_ text: String, mode: ModeID) -> SlotMessage`
  - `public enum Maidenhead { public static func isGrid(_ s: String) -> Bool; public static func center(_ grid: String) -> (lat: Double, lon: Double)? }`
    accepts 4- or 6-character grids, case-insensitive.
  - `public static func isCallsign(_ s: String) -> Bool`: 3–11 characters, at least one digit and one letter,
    `/` allowed, with `<…>` hashed calls unwrapped.

- [ ] **Step 1: Write the failing tests:**
  - `cqWithGrid`: `parse("CQ K1ABC FN42", .ft8)` → `kind == .cq`, `from == "K1ABC"`, `grid == "FN42"`.
  - `cqWithModifier`: `"CQ DX K1ABC FN42"` and `"CQ POTA W1AW FN31"` → from and grid as above. The modifier is
    ignored.
  - `callPairWithGrid`: `"W9XYZ K1ABC FN42"` → `.call`, `to == "W9XYZ"`, `from == "K1ABC"`, grid `"FN42"`.
  - `reports`: `"W9XYZ K1ABC -12"` → `.report`, report `"-12"`. `"W9XYZ K1ABC R-07"` → `.rogerReport`.
    `"W9XYZ K1ABC RR73"` → `.rr73`. `"W9XYZ K1ABC RRR"` → `.rrr`. `"W9XYZ K1ABC 73"` → `.seventyThree`.
  - `rr73IsNotAGrid`: grid stays nil for `RR73`.
  - `wsprMessage`: `parse("K1ABC FN42 37", .wspr)` → `.wspr`, from `"K1ABC"`, grid `"FN42"`, report `"37"`.
  - `hashedCall`: `"<PJ4/K1ABC> W9XYZ"` → `to == "PJ4/K1ABC"`.
  - `freeTextIsOther`: `"TNX BOB 73 GL"` → `.other`, from nil.
  - `gridCenters`: `center("FN42")` ≈ (42.5, −71.0) within 0.01, `center("JO65ab")` ≈ (55.0208, 12.0417)
    within 0.001, `center("ZZ99")` == nil, `center("FN4")` == nil.
- [ ] **Step 2:** Run `swift test --filter SlotMessageTests`. Expected: FAIL to compile (`SlotMessage` not
  defined).
- [ ] **Step 3: Implement.** Tokenize on whitespace, case-insensitively. A grid is `[A-R]{2}[0-9]{2}`
  optionally followed by `[A-X]{2}`, and `RR73` is never a grid. The centre is the square's middle: field
  20°×10°, square 2°×1°, subsquare 5′×2.5′.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat(modems): parse FT8/WSPR messages and Maidenhead grids`.

### Task 2: Decode history

**Files:**
- Create: `Sources/Modems/Framework/DecodeHistory.swift`
- Modify: `Sources/SubFloor/App/AppModel.swift`: add a `let decodeHistory: DecodeHistory` initialised in
  `init`, an injectable `decodeHistoryFolder: URL?` init parameter (nil = the default folder), and an append
  in `pumpModem()` for `batch.slotDecodes`.
- Test: `Tests/ModemsTests/DecodeHistoryTests.swift`, `Tests/SubFloorTests/AppModelDecodeHistoryTests.swift`

**Interfaces:**
- Consumes: `SlotMessage.parse`, `Maidenhead.center` (Task 1), `SlotDecode` (`ModemTypes.swift`).
- Produces:
  - `public struct HeardDecode: Codable, Equatable, Sendable { time: Date; mode: String; rfHz: Double; audioHz: Double; snrDb: Float; message: String; kind: String; from: String?; to: String?; grid: String?; lat: Double?; lon: Double? }`
  - `public static func from(_ d: SlotDecode, rfHz: Double) -> HeardDecode`
  - `public final class DecodeHistory: @unchecked Sendable`:
    - `init(folder: URL, keepDays: Int = 30, now: @escaping @Sendable () -> Date = Date.init)`
    - `func append(_ decodes: [HeardDecode])` writes on a private serial queue.
    - `func decodes(since: Date, until: Date = .distantFuture, mode: String? = nil) -> [HeardDecode]` returns
      the newest first, read from memory for the last 168 h and loaded lazily from the day files.
    - `func stations(since: Date) -> [HeardStation]` gives one row per `from` callsign:
      `HeardStation { call, grid?, lat?, lon?, bestSnrDb, lastHeard, count, bands: [String] }`. The band
      names come from `BandPlan.name(forHz:)`, which is new and lives in the same file.
    - `func flush()` is for tests.
    - `static var defaultFolder: URL`.
  - `public enum BandPlan { public static func name(forHz: Double) -> String? }`: "160m" … "70cm" for the
    amateur bands, else nil.

- [ ] **Step 1: Write the failing tests:**
  - `appendsToTheUTCDayFile`: two decodes 23:59:50Z and 00:00:10Z the next day go into two `.jsonl` files
    named by UTC day. The folder is created on first write.
  - `queriesNewestFirstAndByMode`.
  - `stationsKeepBestSnrLatestGridAndBands`: one call heard on 7.074 and 14.074 MHz with SNRs −20 and −5 →
    `bestSnrDb == -5`, `bands == ["40m", "20m"]` (in the order first heard), `count == 2`.
  - `prunesDayFilesOlderThanKeepDays`: on init with `now` 31 days after a file's day, that file is deleted.
  - `survivesACorruptLine`: a garbage line in a day file is skipped and the others load.
  - `AppModelDecodeHistoryTests.slotDecodesReachTheHistory`: feed a model a `SlotDecode` through the same
    path `pumpModem` uses. If `pumpModem` can't be reached, factor `recordSlotDecodes(_ decodes: [SlotDecode])`
    out of it and test that. Expect a `HeardDecode` with `rfHz == modemBox.rfHz(forAudio: audioHz)`.
- [ ] **Step 2:** Run `swift test --filter "DecodeHistoryTests|AppModelDecodeHistoryTests"`. Expected: FAIL to
  compile.
- [ ] **Step 3: Implement.** Use the types above. In AppModel, tests pass a temp folder; production uses
  `DecodeHistory.defaultFolder`.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat(modems): keep 30 days of parsed FT8/WSPR decodes`.

### Task 3: MCP protocol core (pure)

**Files:**
- Create in `Sources/SubFloor/MCP/`:
  - `MCPHTTP.swift`: the parser and responses.
  - `MCPAuth.swift`: the token, compare and origin check.
  - `MCPSessions.swift`.
  - `MCPRPC.swift`: the dispatch.
  - `MCPLog.swift`.
  - `MCPTool.swift`: the provider protocol, descriptor and result.
- Test: `Tests/SubFloorTests/MCPCoreTests.swift`

**Interfaces:**
- Consumes: `JSONValue` (Transcription target). Add `public init(_ any: Any)`-free helpers in a
  `JSONValue+MCP.swift` extension in `Sources/SubFloor/MCP/`: `subscript(key: String) -> JSONValue?`,
  `var string: String?`, `var double: Double?`, `var bool: Bool?`, `var array: [JSONValue]?`,
  `var object: [String: JSONValue]?`, `func encoded() -> Data` and `static func decode(_ data: Data) -> JSONValue?`.
- Produces:
  - **HTTP:**
    - `struct HTTPRequest: Equatable { var method: String; var path: String; var headers: [String: String] /* lower-cased names */; var body: Data }`
    - `enum HTTPParseResult: Equatable { case incomplete; case request(HTTPRequest, consumed: Int); case failure(status: Int, message: String) }`
    - `enum HTTPParser { static func parse(_ buffer: Data, maxHeaderBytes: Int = 65_536, maxBodyBytes: Int = 16_777_216) -> HTTPParseResult }`
    - `struct HTTPResponse { var status: Int; var headers: [(String, String)]; var body: Data; func serialized() -> Data }`.
      It adds Content-Type `application/json` (for an empty 202 too), Content-Length and
      `Cache-Control: no-store`, and sets `Connection: keep-alive` unless closing.
  - **Auth:** `enum MCPAuth { static func generateToken() -> String; static func sameToken(_ given: String?, _ expected: String) -> Bool; static func isLocalOrigin(_ origin: String?) -> Bool }`
  - **Sessions:**
    - `struct MCPSessions { static let connectedSeconds: TimeInterval = 300; mutating func begin(client: String, now: Date) -> String /* uuid */; mutating func touch(_ id: String?, now: Date) -> (client: String, isNew: Bool); mutating func end(_ id: String) -> String?; func clientName(_ id: String?) -> String?; func connectedClient(now: Date) -> String? /* most recent */ }`
    - Ids from before a restart are remembered by `knownClients`.
  - **Tools:**
    - `struct MCPToolDescriptor { var name: String; var title: String; var description: String; var inputSchema: JSONValue; var readOnly: Bool }`
    - `struct MCPToolResult { var content: String; var structured: JSONValue?; var isError: Bool; static func ok(_ value: JSONValue, summary: String? = nil) -> MCPToolResult; static func failure(_ message: String) -> MCPToolResult }`.
      The `content` text is the JSON or the message.
    - `@MainActor protocol MCPToolProvider: AnyObject { var tools: [MCPToolDescriptor] { get }; func call(_ name: String, arguments: [String: JSONValue], client: String) async -> MCPToolResult }`
  - **Log:**
    - `struct MCPEvent: Codable, Identifiable, Equatable { var id: UUID; var time: Date; var kind: Kind; var client: String?; var summary: String; var detail: String? }`
    - `enum Kind: String, Codable, CaseIterable { case server, connect, disconnect, call, result, error, auth }`, with display names "Server", "Connected", "Disconnected", "Tool call", "Result", "Error", "Refused".
    - `@MainActor @Observable final class MCPLog { init(fileURL: URL?, maxEvents: Int = 1_000, maxFileBytes: Int = 1_048_576); private(set) var events: [MCPEvent]; func add(_ kind: MCPEvent.Kind, client: String?, _ summary: String, detail: String? = nil); func clearView(); static var defaultFileURL: URL }`.
      The file is written off the main thread, and trimmed by dropping the oldest lines.
  - **Dispatch:**
    - `@MainActor final class MCPRPC { init(provider: MCPToolProvider, log: MCPLog, token: @escaping () -> String, now: @escaping () -> Date = Date.init); var sessions: MCPSessions; var onActivity: (() -> Void)?; func handle(_ request: HTTPRequest) async -> HTTPResponse }`
    - **Checks:** origin, then path, then auth, then method.
    - **JSON-RPC:** `initialize`, `notifications/*`, `ping`, `tools/list` and `tools/call`; error `-32601` for an
      unknown method, `-32700` for a parse error, and `-32600` for an invalid request.
    - **Results:** `tools/call` wraps the result as `{content: [{type: "text", text}], isError, structuredContent?}`.
      `structuredContent` is sent only when the session's protocol is `2025-06-18`.
    - **Batches:** a JSON array is a batch, answered with an array.
    - **Notifications only:** answered `202` with an empty body.
    - **Session header:** `Mcp-Session-Id` is echoed.
    - **Session state:** sessions are touched as the spec says.
    - **Logging:** each call is logged as call then result or error, with arguments and the result shortened to
      300 and 600 characters.
    - **Instructions text:**
      `"SubFloor is a receive-only SDR app on this Mac (SDRplay RSP1B, optional HamItUp upconverter). Frequencies are display Hz (what the listener means, HamItUp offset removed). Call get_status first. Before recording, use listen to compare signal with noise and set the squelch a few dB above the noise. Recordings an agent starts stop by themselves."`

- [ ] **Step 1: Write the failing tests** in `MCPCoreTests`:
  - `parsesSplitAndPipelinedRequests`: a request's bytes fed in three slices give `.incomplete`,
    `.incomplete`, then `.request`. Two requests in one buffer come back one after the other via `consumed`.
  - `rejectsOversizeHeadersAndBodies`: 70 KB of headers with no terminator → `.failure(431, …)`.
    `Content-Length: 20000000` → `.failure(413, …)`.
  - `tokensAre43Base64urlCharacters`: `generateToken().count == 43`, using only `[A-Za-z0-9_-]`, with two calls
    differing. `sameToken("Bearer x"…)` is not the API: `sameToken(nil, t) == false`, `sameToken(t, t) == true`,
    `sameToken(t + "a", t) == false`.
  - `originRules`: `nil`, `"null"`, `"http://localhost:3000"`, `"https://127.0.0.1"` and `"http://[::1]:8080"`
    are allowed. `"https://evil.example"` and `"http://localhost.evil.com"` are refused.
  - `refusesWrongTokenAndBadOrigin`: through `MCPRPC.handle`, no token → 401 with
    `WWW-Authenticate: Bearer realm="subfloor"` and a `.auth` log event. A bad origin → 403. `/foo` → 404.
    `GET /mcp` → 405 with `Allow: POST, DELETE`.
  - `initializeNegotiatesAndNamesTheClient`: a `clientInfo` of `{name: "claude-code", version: "2.1"}` with
    protocol `"2025-03-26"` gets version `"2025-03-26"`, the serverInfo name `"subfloor"`, and an
    `Mcp-Session-Id` header. `sessions.connectedClient(now:) == "claude-code 2.1"`. An unknown version gets
    `"2025-06-18"`.
  - `notificationGets202`, `pingAnswers`, `unknownMethodIsMinus32601`, `batchAnswersEachRequest`.
  - `toolsListAndCall`: with a fake provider, `tools/list` lists its descriptors with `inputSchema`, and a call
    returns its text. A failure gets `isError: true` and a `.error` log event.
  - `connectedExpiresAfter300s`: with `now` advanced 301 s, `connectedClient` is nil.
  - `unknownSessionCountsAsConnected`: a `tools/call` with an unseen `Mcp-Session-Id` makes the client
    "MCP client" connected.
  - `logTrimsItsFile`: with `maxFileBytes: 2_000`, 100 events leave a file of at most 2,000 bytes, with the
    newest line last.
- [ ] **Step 2:** Run `swift test --filter MCPCoreTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat(mcp): protocol core (HTTP, auth, sessions, JSON-RPC, log)`.

### Task 4: MCP server, settings and lifecycle

**Files:**
- Create in `Sources/SubFloor/MCP/`:
  - `MCPServer.swift`
  - `MCPSettings.swift`
- Modify:
  - `Sources/SubFloor/App/APIKeyStore.swift`: `KeychainAPIKeyStore` takes `service`/`account` init
    parameters, defaulting to the current OpenRouter values.
  - `Sources/SubFloor/App/SubFloorApp.swift`: AppDelegate owns `mcp: MCPServer?`, created and applied when
    `model` is set (in the `onAppear` that sets `appDelegate.model`), and stopped in
    `applicationWillTerminate` or the existing shutdown path.
- Test: `Tests/SubFloorTests/MCPServerTests.swift`

**Interfaces:**
- Consumes: Task 3's `MCPRPC`, `MCPLog`, `MCPToolProvider`.
- Produces:
  - `struct MCPSettings: Codable, Equatable { var enabled = false; var port = 7824; static func load(_ d: UserDefaults) -> MCPSettings; func save(_ d: UserDefaults); var url: String /* http://127.0.0.1:<port>/mcp */ }`
  - `enum MCPState: Equatable { case off, failed(String), listening, connected(client: String) }`
  - `@MainActor @Observable final class MCPServer`:
    - `init(provider: MCPToolProvider, defaults: UserDefaults = .standard, tokenStore: APIKeyStore = KeychainAPIKeyStore(service: "app.subfloor.SubFloor.mcp", account: "token"), log: MCPLog = MCPLog(fileURL: MCPLog.defaultFileURL))`
    - `private(set) var state: MCPState`
    - `private(set) var settings: MCPSettings`
    - `private(set) var token: String`: created and saved on first use if the Keychain has none.
    - `private(set) var pulse: Int`: incremented once per handled request.
    - `private(set) var boundPort: UInt16?`
    - `let log: MCPLog`
    - `func apply(_ s: MCPSettings) async`: start, restart on a port change, or stop. It saves the settings.
    - `func newToken()`: a new token, saved, and the server restarted so open connections close.
    - `func stop()`
  - **The listener:** `NWListener` with `.tcp` parameters, `requiredLocalEndpoint` 127.0.0.1, on a private
    queue. Each connection reads into a buffer, parses with `HTTPParser`, awaits `rpc.handle` on the main
    actor, and writes the reply. Requests on one connection are handled in order.
  - **State:** recomputed from `rpc.sessions.connectedClient(now:)` after every request and on a 5 s timer.
  - **Port 0** (tests only) binds an ephemeral port and reports it through `boundPort`.
  - **A port in use** gives `.failed("Port <n> is in use")`, the log line
    `"Could not start on port <n>: <error>"`, and settings still saved with enabled true. Retrying apply or a
    port change tries again.

- [ ] **Step 1: Write the failing tests:**
  - `servesOverLoopback`: apply `MCPSettings(enabled: true, port: 0)`, then POST `initialize` with
    `URLSession` to `http://127.0.0.1:<boundPort>/mcp` with the token → 200, `result.serverInfo.name == "subfloor"`.
    Then `tools/list` with the session id → `state == .connected(client: "test 1.0")`.
  - `busyPortFailsCleanly`: bind a port with a plain NWListener first, then apply that port →
    `state == .failed("Port <n> is in use")` and a log `.error` line.
  - `newTokenRefusesTheOldOne`: after `newToken()`, a request with the old token → 401 and a `.auth` event.
  - `offByDefaultAndPersists`: a fresh defaults suite gives `settings.enabled == false`, port 7824. Applying
    enabled on port 0 and making a new server from the same defaults → enabled.
  - `tokenSurvivesRestart`: with a `MemoryAPIKeyStore`, two servers on the same store share the token.
- [ ] **Step 2:** Run `swift test --filter MCPServerTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat(mcp): local server with Keychain token, settings and lifecycle`.

### Task 5: Radio, spectrum, cursor and bookmark tools

**Files:**
- Create in `Sources/SubFloor/MCP/Tools/`:
  - `SubFloorTools.swift`: the provider, registry, argument helpers and radio lock.
  - `RadioTools.swift`
  - `BookmarkTools.swift`
- Modify `Sources/SubFloor/App/AppModel.swift`:
  - `private(set) var lastPointer: PointerReadout?` (`struct PointerReadout: Equatable { var hz: Double; var db: Float?; var at: Date }`),
    set in `hover(at:)` whenever the readout is non-nil and kept when it becomes nil.
  - `func spectrumSnapshot() -> SpectrumSnapshot?` (`struct SpectrumSnapshot { var centerHz: Double; var spanHz: Double; var average: [Float] }`)
    built from `engine.frames.readFrame(after: 0, …)` and `centerHz`/`sampleRate`.
- Test: `Tests/SubFloorTests/MCPRadioToolsTests.swift`

**Interfaces:**
- Consumes: `MCPToolProvider` and `MCPToolResult` (Task 3); `AppModel` APIs: `start()`, `stop()`,
  `tune(to:keepZoom:)`, `setMode`, `setBandwidth`, `setUpconverter`, `squelchEnabled`, `squelchDb`, `signalDb`,
  `upconverter`, `vfoHz`, `centerHz`, `sampleRate`, `bookmarks`, `addBookmark(_:)`, `updateBookmark`,
  `deleteBookmark`, `modemBox`, `modemCursorAudioHz`, `decodeLog`.
- Produces:
  - `@MainActor final class SubFloorTools: MCPToolProvider { init(model: AppModel) }`
  - `func withRadio<T>(_ body: () async -> T) async -> T`: an async FIFO lock that serializes the mutating
    tools.
  - Argument helpers: `frequency(_:)` accepts a number or a string via `FrequencyParser`; `int`, `double`,
    `bool` and `string` take defaults and clamps.
  - Every result has `"ok": true` or `isError`.
- Tools and their results (JSON keys are snake_case):
  - `get_status` → `{running, source, device, vfo_hz, center_hz, span_hz, mode, bandwidth_hz, hamitup: {on, lo_hz}, squelch: {on, level_dbfs}, signal_dbfs, recording: {audio, iq, auto_state}, decoder, transcription: {on, has_key}, mcp_clients}`
  - `start_radio` / `stop_radio` → the status subset `{running, source}`.
  - `tune {frequency, mode?, bandwidth_hz?, hamitup?: "on"|"off"|"auto"}`. `auto` turns HamItUp on for
    frequencies under 30 MHz when `upconverter.loHz` is set and the frequency is reachable through it, and
    otherwise leaves it. The result is `{vfo_hz, mode, bandwidth_hz, hamitup}`. If the requested frequency is
    outside `[1 kHz, 2 GHz − LO when HamItUp is on]`, the tool fails with "<f> is outside what the RSP1B can
    tune (1 kHz – 2 GHz)…" and doesn't tune.
  - `set_squelch {enabled?, level_dbfs?}` → `{on, level_dbfs, signal_dbfs}`.
  - `get_cursor` → `{mouse: {hz, level_dbfs?, seconds_ago, nearest_bookmark?, decodes_near: [...]}?, decoder_cursor: {...}?, vfo: {...}}`.
    "Near" means within ±(bandwidth / 2).
  - `get_spectrum {from_hz?, to_hz?, points? (16–2048, default 512)}` → `{from_hz, to_hz, bin_hz, levels_dbfs: [...max-held per point], peaks: [{hz, level_dbfs, width_hz}]}`.
    Peaks are local maxima at least 6 dB above the median of the window, with the −6 dB width, the strongest
    20. A range outside the capture fails with "Tune within … first."
  - `list_bookmarks {query?, group?}`.
  - `add_bookmark {name, frequency, mode?, bandwidth_hz?, group?, notes?, hamitup?}`: `addedBy` = client, and
    the result is `{id}`.
  - `update_bookmark {id, …same fields, append_notes?}`: on an owner bookmark, any field other than
    `append_notes` fails with "That bookmark is the owner's: only append_notes is allowed."
  - `delete_bookmark {id}`: only `isFromAgent` bookmarks.
- Wire `SubFloorTools(model:)` in as the provider in Task 4's AppDelegate wiring.

- [ ] **Step 1: Write the failing tests.** Use a demo-source model as in `CentredTuningTests.makeModel()`, and
  call the tools through `SubFloorTools.call`:
  - `statusReportsTheTuning`: `vfo_hz`, `mode` and `hamitup.on` match the model.
  - `tuneAcceptsStringsAndModes`: `tune {frequency: "7.200 MHz", mode: "lsb"}` → `model.vfoHz == 7_200_000`,
    `model.mode == .lsb`.
  - `tuneRejectsUnreachableFrequencies`: `"abc"`, `-5` and `5e9` each give `isError`, with `vfoHz` unchanged.
  - `hamitupAutoUsesTheUpconverterOnHF`: `tune {frequency: 6_925_000, hamitup: "auto"}` →
    `model.upconverter.enabled == true`. At 144.39 MHz with auto, it stays as it was.
  - `squelchTool`.
  - `cursorRemembersTheMouse`: `model.hover(at:)` over the spectrum, then `hover(at: nil)` →
    `get_cursor.mouse.hz` is the hovered frequency.
  - `spectrumAfterTheDemoRuns`: start the demo source, wait for a frame (up to 3 s), call `get_spectrum`
    with `points: 64` → 64 levels and `bin_hz > 0`.
  - `agentBookmarksAreMarkedAndOwnedOnesProtected`:
    - `add_bookmark` with client "claude-code 2.1" sets `addedBy == "claude-code 2.1"`.
    - `update_bookmark` of a default bookmark with `name` → `isError`; with `append_notes: "heard 0500Z"` the
      notes end with that.
    - `delete_bookmark` of a default bookmark → `isError`; of the agent's → it is removed.
  - `mutatingToolsRunOneAtATime`: two concurrent `tune` calls complete in order with no interleaving. Use
    `withRadio` with a probe.
- [ ] **Step 2:** Run `swift test --filter MCPRadioToolsTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat(mcp): radio, spectrum, cursor and bookmark tools`.

### Task 6: Listening, recording, decoder and transcript tools

**Files:**
- Create:
  - `Sources/SubFloor/Engine/AudioTap.swift`
  - `Sources/SubFloor/MCP/Tools/RecordingTools.swift`
  - `Sources/SubFloor/MCP/Tools/DecodeTools.swift`
- Modify:
  - `Sources/SubFloor/Engine/DSPEngine.swift`: `let audioTap = AudioTap()`, pushed on the DSP thread with
    `receiver.ungatedAudio` and `receiver.isSquelchOpen` after `receiver.process`, and cleared on `start`.
  - `Sources/SubFloor/App/AppModel.swift`: expose `transcriptionKey: String?` (from the existing key store),
    `transcribeFunction` (the injected `TranscribeFunction`), and `func saveListenClip(_ samples: [Float], rate: Double, start: Date) throws -> String`.
    The clip is written as FLAC/WAV into the recordings folder with a `RecordingFileName` and a log entry,
    so it shows in Recordings.
- Test: `Tests/SubFloorTests/MCPListenRecordingToolsTests.swift`, `Tests/SubFloorTests/AudioTapTests.swift`

**Interfaces:**
- Consumes: `SubFloorTools.withRadio` and the argument helpers (Task 5); `DecodeHistory` (Task 2);
  `TranscriptionAudio.prepare(samples:)`, `TranscriptClassifier.classify`, `TranscriptIndex`,
  `TranscriptSearch.terms`, `RecordingsCatalog.allRecordings`.
- Produces:
  - `final class AudioTap: @unchecked Sendable { init(seconds: Double = 60, rate: Double = Receiver.audioRate); func push(_ audio: UnsafeBufferPointer<Float>, gateOpen: Bool); struct Mark { let total: Int; let open: Int }; func mark() -> Mark; func samples(since: Mark) -> [Float] /* at most `seconds` */; func openSeconds(since: Mark) -> Double; func clear() }`.
    It is a preallocated ring under a `Mutex` and never allocates on push.
- Tools:
  - **`listen {seconds?, transcribe?, keep?}`:**
    - It holds the radio lock, records a `mark()` and the tuning (vfo, mode, running), then samples
      `model.signalDb` every 200 ms.
    - It ends early with `{interrupted: "retuned to 7.200 MHz" | "the radio stopped" | "mode changed to AM"}`
      if any of those change.
    - Otherwise it returns `{seconds, level_dbfs: {min, median, max}, squelch_open_seconds, transcript?: {text, verdict: "voice"|"possible_noise", words}, transcribed: Bool, note?}`.
    - It transcribes only if `transcriptionSettings.enabled`, a key exists and `transcribe != false`, by
      resampling to 16 kHz, `TranscriptionAudio.prepare(samples:)`, `transcribeFunction` with the settings'
      model/language, then `TranscriptClassifier`. Otherwise `note` explains why there is no transcript.
  - **`start_recording {kind: "audio"|"iq"|"both", max_minutes?}`** fails if the radio isn't running. It
    schedules a stop after `max_minutes`, cancelled if the owner stops it first, and returns
    `{started: [...], stops_at}`.
  - **`stop_recording {kind?}`.**
  - **`set_auto_record {on, minutes?}`** fails with "Turn the squelch on first (set_squelch)" if the squelch is
    off. With `on`, a task turns Auto off at the deadline, unless the owner turned Auto off and on by hand
    since then (keep a generation counter). The result is `{on, auto_state, off_at?}`.
  - **`list_recordings {since?, until?, frequency?, tolerance_hz? (default 5000), voice_only?, limit? (default 50)}`**
    returns the newest first.
  - **`get_transcript {file}`** and **`search_transcripts {query, limit?}`**.
  - **`set_decoder {mode: "ft8"|"wspr"|"cw"|"psk31"|"rtty"|"off"}`** calls `setModemMode`. If the requested
    mode isn't offered by `ModemControl.offeredModes`, the tool fails and lists the offered modes.
  - **`get_decodes {since_minutes? (default 15), mode?}`** returns the slot decodes from `DecodeHistory` plus
    the live rows (CW/PSK31) from `decodeLog`.
  - **`get_ft8_stations {hours?}`** returns `DecodeHistory.stations` for FT8.

- [ ] **Step 1: Write the failing tests:**
  - `AudioTapTests.keepsTheLastSecondsAndCountsOpenTime`: push 70 s of a 48 kHz ramp in 4800-sample blocks,
    half of them `gateOpen` → `samples(since: start)` is 60 s long and ends with the last sample;
    `openSeconds(since:)` ≈ 35.
  - `listenReportsLevelsAndTranscribesWhenOn`: run the demo source, turn transcription on with a
    `MemoryAPIKeyStore` key, and inject a fake `transcribe` returning the "voice" fixture
    (`Tests/TranscriptionTests/Fixtures/SubFloor_20261028_140122Z_11175000Hz_USB.json`). Then
    `listen {seconds: 2}` → `transcript.verdict == "voice"` and `level_dbfs.median` is finite.
  - `listenSkipsTranscriptionWhenTheSwitchIsOff`: `transcribed == false`, and `note` mentions "Transcribe
    Recordings". The fake is never called.
  - `listenStopsWhenTheOwnerRetunes`: start `listen {seconds: 10}`, retune with `model.tune(to:)` 0.5 s later
    → the result has `interrupted` beginning "retuned to", and it returns within 1.5 s.
  - `recordingStopsByItself`: `start_recording {kind: "audio", max_minutes: 0.02}` (1.2 s; allow fractional
    minutes in tests) → after 3 s, `model.isRecording(.audio) == false`.
  - `recordingNeedsTheRadio`: with the radio stopped → `isError`, and the message says to call `start_radio`.
  - `autoNeedsSquelchAndTurnsItselfOff`: with the squelch off → `isError`. With it on and `minutes: 0.02` →
    Auto is on, then off within 3 s.
  - `decodesAndStationsFromHistory`: seed `DecodeHistory` with three FT8 decodes → `get_ft8_stations` lists
    two calls with lat/lon.
  - `listRecordingsFiltersByFrequencyAndVoice`: use the transcript fixtures as the earlier STT tests do.
- [ ] **Step 2:** Run `swift test --filter "MCPListenRecordingToolsTests|AudioTapTests"`. Expected: FAIL to
  compile.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit `feat(mcp): listen, recording, decoder and transcript tools`.

### Task 7: The MCP button, the window and the agent snippets

**Files:**
- Create:
  - `Sources/SubFloor/MCP/AgentSnippets.swift`
  - `Sources/SubFloor/MCP/AgentInstaller.swift`
  - `Sources/SubFloor/UI/MCP/MCPButton.swift`
  - `Sources/SubFloor/UI/MCP/MCPWindow.swift`
- Modify:
  - `Sources/SubFloor/UI/TopBarView.swift`: `MCPButton()` right after `DialChip()`.
  - `Sources/SubFloor/App/SubFloorApp.swift`: `Window("MCP Server", id: "mcp")` with
    `.defaultLaunchBehavior(.suppressed)`, Radio › "MCP Server…", and the server injected via `.environment`.
- Test: `Tests/SubFloorTests/MCPUITests.swift`

**Interfaces:**
- Consumes: `MCPServer` (`state`, `pulse`, `settings`, `token`, `apply`, `newToken`, `log`) from Task 4.
- Produces:
  - `struct AgentSnippet: Identifiable { var id: String; var name: String; var whereItGoes: String; var text: String; var install: AgentInstall? }`
  - `struct AgentInstall { var executable: String /* e.g. "claude" */; var arguments: [String]; var stdin: String? }`
  - `enum AgentSnippets { static func all(url: String, token: String) -> [AgentSnippet] }`, in the spec's
    order: Claude Code, Claude Code plugin, Claude Desktop, Hermes Agent, Hermes (config.yaml), Codex CLI,
    Gemini CLI, Cursor, VS Code, Windsurf, LM Studio, Goose, Any other client.
  - **Snippet formats:** take each from
    `/private/tmp/claude-501/-Users-war-Desktop-code-subfloor--claude-worktrees-auto-record-squelch-break-f7413a/6486b2d9-dcb2-4e6e-bbb9-37e45dd3e07a/scratchpad/mcp-client-formats.md`
    (the controller copies the verified formats into the task brief). Where a format is only "inferred",
    keep the snippet and say "check your client's docs" in `whereItGoes`.
  - **Install commands:** `install` is set only for clients with a non-interactive add command:
    - Claude Code: `claude mcp add --transport http -s user subfloor <url> --header "Authorization: Bearer <token>"`
    - Codex, if the verified format allows a non-interactive token. Otherwise there is no install.
    - Hermes, if its token prompt can be fed on stdin. Otherwise there is no install.
  - `@MainActor enum AgentInstaller { static func locate(_ executable: String) -> URL?; static func run(_ install: AgentInstall) async -> (ok: Bool, output: String) }`.
    It looks in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` and `~/.npm-global/bin`, plus the login
    shell's PATH from `/bin/zsh -lc 'command -v <exe>'`. It runs with a 30 s timeout.
  - **MCPButton:**
    - Pill size 74×24.
    - Colours: Off is grey `(150,157,168)`, listening is blue (`Theme.accent`), connected is green
      `(30,154,84)`.
    - While connected it has a steady glow (shadow radius 6, opacity 0.55) and the dot glows. When `pulse`
      changes it eases up to full glow and back over 0.6 s, coalesced, with no animation otherwise.
    - The failed state shows an orange `exclamationmark.triangle.fill`.
    - The tooltips are the spec's exact strings.
    - A click opens the window `mcp`.
  - **MCPWindow:**
    - **Setup tab:**
      - The enable toggle, the port field with Apply, and the status line (the spec's exact strings).
      - The token field, hidden by default, with Show/Hide, Copy, and New Token (with a confirmation alert).
      - "Connect an agent": a list of `AgentSnippets.all(...)` on the left and the selected snippet on the
        right in monospaced text, with Copy and, when `install != nil` and `locate` finds it,
        "Add to <name>". Its output is shown below.
      - The skill line.
    - **Event log tab:** a `Table` of `log.events` (Time, Event, Client, Summary) with a filter field,
      "Clear view" and "Open log folder", and the selected event's detail below.
  - Display strings: `MCPButton.tooltip(for: MCPState, port: Int) -> String` and
    `MCPWindow.statusLine(for: MCPState, url: String) -> String` (static, testable).

- [ ] **Step 1: Write the failing tests:**
  - `snippetsFillUrlAndToken`: every snippet's `text` contains the URL `http://127.0.0.1:7900/mcp` and the
    token `"tok123"`, except "Claude Code plugin", which uses `SUBFLOOR_MCP_TOKEN=tok123`. The ids are unique,
    with 13 entries in the spec's order.
  - `claudeCodeInstallIsNonInteractive`: its `install.arguments` equal
    `["mcp", "add", "--transport", "http", "-s", "user", "subfloor", url, "--header", "Authorization: Bearer tok123"]`.
  - `tooltipsAndStatusLines`: each state maps to the spec's exact strings, for example
    `.connected(client: "Claude Code 2.1")` → `"Claude Code 2.1 connected"`.
  - `buttonRendersEachState`: render `MCPButton` offscreen for off, failed, listening and connected (as the
    earlier `ZZScratch` renders did, with `NSHostingView` and `cacheDisplay`) and check the image isn't empty.
    Commit no PNGs.
- [ ] **Step 2:** Run `swift test --filter MCPUITests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Run the tests. Expected: PASS. Then render the window's two tabs and the button's four
  states to the scratchpad, and look at them.
- [ ] **Step 5:** Commit `feat(mcp): glowing MCP button, setup window with agent snippets, event log`.

### Task 8: Plugin, skill, README, and end-to-end with real agents

**Files:**
- Create:
  - `.claude-plugin/marketplace.json`: name `subfloor`, owner RidgebackZulu, one plugin with source
    `./plugins/subfloor`.
  - `plugins/subfloor/.claude-plugin/plugin.json`
  - `plugins/subfloor/plugin.json`: the agent-plugins schema, as Cadjitsu's.
  - `plugins/subfloor/.mcp.json`: `{"mcpServers": {"subfloor": {"type": "http", "url": "${SUBFLOOR_MCP_URL:-http://127.0.0.1:7824/mcp}", "headers": {"Authorization": "Bearer ${SUBFLOOR_MCP_TOKEN}"}}}}`.
  - `plugins/subfloor/README.md`
  - `plugins/subfloor/skills/subfloor-radio/SKILL.md`
  - `plugins/subfloor/skills/subfloor-radio/references/tools.md`
- Modify `README.md`:
  - A feature bullet "🤖 **AI agents can drive it.**"
  - A section "## 🤖 AI agents (MCP)": switch it on, pick your agent, paste or click Add, and the example
    prompts from the spec.
  - The Radio menu table gains MCP Server….
- Test: `Tests/SubFloorTests/MCPPluginTests.swift`

**Interfaces:**
- Consumes: the tool names and arguments from Tasks 5–6. `tools.md` must list exactly
  `SubFloorTools.tools.map(\.name)`.
- Produces: no code.

- [ ] **Step 1: Write the failing test `pluginDocumentsEveryTool`.** It reads
  `plugins/subfloor/skills/subfloor-radio/references/tools.md` (from `#filePath` up to the repo root) and
  checks that every `SubFloorTools` tool name appears as a "### `name`" heading, and no other heading
  appears. It also checks that `.mcp.json` parses and contains port 7824.
- [ ] **Step 2:** Run it. Expected: FAIL (the files are missing).
- [ ] **Step 3: Write the plugin, the skill and the README.** The skill's frontmatter is `name: subfloor-radio`,
  with a description naming the triggers: radio, SDR, frequency, shortwave, pirate, FT8, record, bookmark,
  SubFloor. It has these sections:
  - Connect
  - Frequencies and HamItUp
  - Listening before recording (squelch above the noise)
  - Hunting (pirates, broadcasts)
  - Logging (bookmarks with notes and evidence)
  - FT8 maps (`get_ft8_stations` → the agent builds an HTML/Leaflet map)
  - Callsigns (web lookup)
  - Limits
- [ ] **Step 4:** Run `swift test --filter MCPPluginTests`. Expected: PASS.
- [ ] **Step 5: End to end, by hand.**
  - Build `scripts/bundle.sh` into a copy at the scratchpad. Launch it with the demo source and MCP enabled
    on port **7899**, via defaults on a separate `-AppleDefaults` domain or a `SUBFLOOR_DEFAULTS_SUITE` env
    var if one exists. Otherwise set the `mcp` defaults key, then restore it.
  - Connect each of `claude -p`, `hermes` and `codex exec` using the Setup snippets, with temporary
    configs only. Ask "Use the subfloor tools: get_status, then tune to 7.074 MHz USB and report the VFO."
  - Record each transcript in the ledger. Remove the temporary agent configs afterwards.
  - Never touch the owner's running SubFloor, or its port 7824 config.
- [ ] **Step 6:** Commit `docs(mcp): plugin and skill for Claude Code and Hermes; README`.
