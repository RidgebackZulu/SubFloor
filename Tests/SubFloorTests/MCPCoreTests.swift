import Foundation
import Testing
import Transcription
@testable import SubFloor

/// The MCP protocol core without a socket: HTTP parsing, the token and origin rules, sessions, JSON-RPC
/// dispatch and the event log.
@MainActor
@Suite(.serialized)
struct MCPCoreTests {
    /// A provider with one tool that echoes `text` and one that always fails.
    final class FakeProvider: MCPToolProvider {
        var calls: [(name: String, client: String)] = []
        let tools = [
            MCPToolDescriptor(name: "echo", title: "Echo", description: "Says it back.",
                              inputSchema: .object(["type": .string("object")]), readOnly: true),
            MCPToolDescriptor(name: "fail", title: "Fail", description: "Always fails.",
                              inputSchema: .object(["type": .string("object")]), readOnly: false),
        ]

        func call(_ name: String, arguments: [String: JSONValue], client: String) async -> MCPToolResult {
            calls.append((name, client))
            if name == "fail" { return .failure("The radio is stopped: call start_radio first.") }
            return .ok(.object(["said": arguments["text"] ?? .null]))
        }
    }

    final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private let token = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"

    private func makeRPC() -> (MCPRPC, FakeProvider, MCPLog, Clock) {
        let provider = FakeProvider()
        let log = MCPLog(fileURL: nil)
        let clock = Clock()
        let token = self.token
        let rpc = MCPRPC(provider: provider, log: log, token: { token }, now: { clock.now })
        return (rpc, provider, log, clock)
    }

    private func request(_ method: String = "POST", path: String = "/mcp", body: String = "",
                         session: String? = nil, auth: Bool = true, headers: [String: String] = [:]) -> HTTPRequest {
        var h = headers
        if auth { h["authorization"] = "Bearer \(token)" }
        if let session { h["mcp-session-id"] = session }
        h["content-type"] = "application/json"
        return HTTPRequest(method: method, path: path, headers: h, body: Data(body.utf8))
    }

    private func reply(_ r: HTTPResponse) throws -> JSONValue {
        try #require(JSONValue.decode(r.body))
    }

    private func initialize(_ rpc: MCPRPC, version: String = "2025-03-26") async throws -> String {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)","#
            + #""capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1"}}}"#
        let r = await rpc.handle(request(body: body))
        #expect(r.status == 200)
        return try #require(r.header("Mcp-Session-Id"))
    }

    // MARK: HTTP

    @Test func parsesSplitAndPipelinedRequests() throws {
        let one = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\nX-Thing:  a b \r\n\r\nhello".utf8)
        #expect(HTTPParser.parse(one.prefix(10)) == .incomplete)
        #expect(HTTPParser.parse(one.prefix(60)) == .incomplete)
        guard case .request(let r, let consumed) = HTTPParser.parse(one) else {
            Issue.record("no request"); return
        }
        #expect(consumed == one.count)
        #expect(r.method == "POST")
        #expect(r.path == "/mcp")
        #expect(r.headers["content-length"] == "5")
        #expect(r.headers["x-thing"] == "a b")
        #expect(r.body == Data("hello".utf8))

        let two = Data("DELETE /mcp HTTP/1.1\r\nMcp-Session-Id: s1\r\n\r\n".utf8)
        var buffer = one + two
        guard case .request(let first, let n1) = HTTPParser.parse(buffer) else {
            Issue.record("no first request"); return
        }
        #expect(first.method == "POST")
        buffer.removeFirst(n1)
        guard case .request(let second, let n2) = HTTPParser.parse(buffer) else {
            Issue.record("no second request"); return
        }
        #expect(second.method == "DELETE")
        #expect(second.headers["mcp-session-id"] == "s1")
        #expect(second.body.isEmpty)
        #expect(n2 == buffer.count)
    }

    @Test func rejectsOversizeHeadersAndBodies() {
        let long = "POST /mcp HTTP/1.1\r\n" + String(repeating: "X-Pad: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n", count: 1_600)
        #expect(long.utf8.count > 70_000)
        guard case .failure(let status, _) = HTTPParser.parse(Data(long.utf8)) else {
            Issue.record("oversize headers accepted"); return
        }
        #expect(status == 431)

        let big = Data("POST /mcp HTTP/1.1\r\nContent-Length: 20000000\r\n\r\n{".utf8)
        guard case .failure(let bodyStatus, _) = HTTPParser.parse(big) else {
            Issue.record("oversize body accepted"); return
        }
        #expect(bodyStatus == 413)
    }

    @Test func responsesCarryTheirHeaders() {
        let r = HTTPResponse(status: 202, headers: [("Mcp-Session-Id", "s1")], body: Data())
        let text = String(decoding: r.serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 202 Accepted\r\n"))
        #expect(text.contains("Content-Type: application/json\r\n"))
        #expect(text.contains("Content-Length: 0\r\n"))
        #expect(text.contains("Cache-Control: no-store\r\n"))
        #expect(text.contains("Connection: keep-alive\r\n"))
        #expect(text.contains("Mcp-Session-Id: s1\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
        let closing = HTTPResponse(status: 431, headers: [], body: Data("{}".utf8), close: true)
        let closed = String(decoding: closing.serialized(), as: UTF8.self)
        #expect(closed.hasPrefix("HTTP/1.1 431 Request Header Fields Too Large\r\n"))
        #expect(closed.contains("Connection: close\r\n"))
        #expect(closed.hasSuffix("\r\n\r\n{}"))
    }

    // MARK: Auth

    @Test func tokensAre43Base64urlCharacters() {
        let t = MCPAuth.generateToken()
        #expect(t.count == 43)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        #expect(t.allSatisfy { allowed.contains($0) })
        #expect(MCPAuth.generateToken() != t)
        #expect(MCPAuth.sameToken(nil, t) == false)
        #expect(MCPAuth.sameToken(t, t) == true)
        #expect(MCPAuth.sameToken(t + "a", t) == false)
        #expect(MCPAuth.sameToken("", "") == false)
    }

    @Test func originRules() {
        for ok in [nil, "null", "http://localhost:3000", "https://127.0.0.1", "http://[::1]:8080", "http://localhost"] {
            #expect(MCPAuth.isLocalOrigin(ok), "\(ok ?? "nil")")
        }
        for bad in ["https://evil.example", "http://localhost.evil.com", "http://127.0.0.1.evil.com",
                    "http://localhost:3000.evil.com", "file://localhost"] {
            #expect(!MCPAuth.isLocalOrigin(bad), "\(bad)")
        }
    }

    @Test func refusesWrongTokenAndBadOrigin() async throws {
        let (rpc, _, log, _) = makeRPC()
        let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let noToken = await rpc.handle(request(body: ping, auth: false))
        #expect(noToken.status == 401)
        #expect(noToken.header("WWW-Authenticate") == #"Bearer realm="subfloor""#)
        #expect(log.events.last?.kind == .auth)

        let wrong = await rpc.handle(request(body: ping, auth: false, headers: ["authorization": "Bearer nope"]))
        #expect(wrong.status == 401)

        let origin = await rpc.handle(request(body: ping, headers: ["origin": "https://evil.example"]))
        #expect(origin.status == 403)
        #expect(log.events.last?.kind == .auth)

        #expect(await rpc.handle(request(path: "/foo", body: ping)).status == 404)
        let get = await rpc.handle(request("GET"))
        #expect(get.status == 405)
        #expect(get.header("Allow") == "POST, DELETE")

        let garbled = await rpc.handle(request(body: "{not json"))
        #expect(garbled.status == 400)
        #expect(try reply(garbled)["error"]?["code"]?.double == -32700)
        #expect(try reply(garbled)["id"] == .null)
    }

    // MARK: JSON-RPC

    @Test func initializeNegotiatesAndNamesTheClient() async throws {
        let (rpc, _, log, clock) = makeRPC()
        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","#
            + #""capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1"}}}"#
        let r = await rpc.handle(request(body: body))
        #expect(r.status == 200)
        let json = try reply(r)
        #expect(json["id"] == .number(1))
        #expect(String(decoding: r.body, as: UTF8.self).contains(#""id":1"#))
        #expect(json["result"]?["protocolVersion"]?.string == "2025-03-26")
        #expect(json["result"]?["serverInfo"]?["name"]?.string == "subfloor")
        #expect(json["result"]?["serverInfo"]?["title"]?.string == "SubFloor SDR")
        #expect(json["result"]?["capabilities"]?["tools"] != nil)
        #expect(json["result"]?["instructions"]?.string?.hasPrefix("SubFloor is a receive-only SDR app") == true)
        let session = try #require(r.header("Mcp-Session-Id"))
        #expect(UUID(uuidString: session) != nil)
        #expect(rpc.sessions.connectedClient(now: clock.now) == "claude-code 2.1")
        #expect(rpc.sessions.clientName(session) == "claude-code 2.1")
        #expect(log.events.last?.kind == .connect)

        let newer = #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01","#
            + #""clientInfo":{"name":"x"}}}"#
        let n = try reply(await rpc.handle(request(body: newer)))
        #expect(n["id"]?.string == "a")
        #expect(n["result"]?["protocolVersion"]?.string == "2025-06-18")
    }

    @Test func notificationGets202() async throws {
        let (rpc, _, _, _) = makeRPC()
        let session = try await initialize(rpc)
        let r = await rpc.handle(request(body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                                         session: session))
        #expect(r.status == 202)
        #expect(r.body.isEmpty)
        #expect(r.header("Mcp-Session-Id") == session)
        let text = String(decoding: r.serialized(), as: UTF8.self)
        #expect(text.contains("Content-Type: application/json\r\n"))
    }

    @Test func pingAnswers() async throws {
        let (rpc, _, _, clock) = makeRPC()
        var activity = 0
        rpc.onActivity = { activity += 1 }
        let r = await rpc.handle(request(body: #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#))
        #expect(r.status == 200)
        let json = try reply(r)
        #expect(json["id"] == .number(7))
        #expect(json["result"] == .object([:]))
        #expect(activity == 1)
        // A bare ping without a session is not an agent.
        #expect(rpc.sessions.connectedClient(now: clock.now) == nil)
    }

    @Test func unknownMethodIsMinus32601() async throws {
        let (rpc, _, _, _) = makeRPC()
        let json = try reply(await rpc.handle(request(body: #"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)))
        #expect(json["error"]?["code"]?.double == -32601)
        #expect(json["id"] == .number(3))
        let invalid = try reply(await rpc.handle(request(body: #"{"jsonrpc":"2.0","id":4}"#)))
        #expect(invalid["error"]?["code"]?.double == -32600)
        #expect(invalid["id"] == .number(4))
    }

    @Test func batchAnswersEachRequest() async throws {
        let (rpc, _, _, _) = makeRPC()
        let body = #"[{"jsonrpc":"2.0","id":1,"method":"ping"},"#
            + #"{"jsonrpc":"2.0","method":"notifications/initialized"},"#
            + #"{"jsonrpc":"2.0","id":2,"method":"nope"}]"#
        let r = await rpc.handle(request(body: body))
        #expect(r.status == 200)
        let items = try #require(try reply(r).array)
        #expect(items.count == 2)
        #expect(items[0]["id"] == .number(1))
        #expect(items[0]["result"] != nil)
        #expect(items[1]["id"] == .number(2))
        #expect(items[1]["error"]?["code"]?.double == -32601)

        let notesOnly = #"[{"jsonrpc":"2.0","method":"notifications/initialized"}]"#
        #expect(await rpc.handle(request(body: notesOnly)).status == 202)
    }

    @Test func toolsListAndCall() async throws {
        let (rpc, provider, log, _) = makeRPC()
        let session = try await initialize(rpc, version: "2025-06-18")
        let list = try reply(await rpc.handle(request(body: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                                                      session: session)))
        let tools = try #require(list["result"]?["tools"]?.array)
        #expect(tools.map { $0["name"]?.string } == ["echo", "fail"])
        #expect(tools[0]["inputSchema"] == .object(["type": .string("object")]))
        #expect(tools[0]["title"]?.string == "Echo")
        #expect(tools[0]["description"]?.string == "Says it back.")
        #expect(tools[0]["annotations"]?["readOnlyHint"] == .bool(true))

        let call = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#
        let r = await rpc.handle(request(body: call, session: session))
        #expect(r.header("Mcp-Session-Id") == session)
        let result = try #require(try reply(r)["result"])
        let text = try #require(result["content"]?.array?.first)
        #expect(text["type"]?.string == "text")
        #expect(JSONValue.decode(Data((text["text"]?.string ?? "").utf8)) == .object(["said": .string("hi")]))
        #expect(result["isError"] == .bool(false))
        #expect(result["structuredContent"] == .object(["said": .string("hi")]))
        #expect(provider.calls.last?.client == "claude-code 2.1")
        let kinds = log.events.suffix(2).map(\.kind)
        #expect(kinds == [.call, .result])
        #expect(log.events.suffix(2).first?.summary == "echo")
        #expect(log.events.suffix(2).first?.detail?.contains("hi") == true)

        let fail = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"fail"}}"#
        let f = try #require(try reply(await rpc.handle(request(body: fail, session: session)))["result"])
        #expect(f["isError"] == .bool(true))
        #expect(f["content"]?.array?.first?["text"]?.string == "The radio is stopped: call start_radio first.")
        #expect(log.events.last?.kind == .error)

        // An older protocol gets the text only.
        let old = try await initialize(rpc, version: "2025-03-26")
        let o = try #require(try reply(await rpc.handle(request(body: call, session: old)))["result"])
        #expect(o["structuredContent"] == nil)
        #expect(o["content"]?.array?.count == 1)
    }

    @Test func toolResultsCarryLongArgumentsShortened() async throws {
        let (rpc, _, log, _) = makeRPC()
        let session = try await initialize(rpc)
        let long = String(repeating: "x", count: 2_000)
        let call = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"\#(long)"}}}"#
        _ = await rpc.handle(request(body: call, session: session))
        let events = log.events.suffix(2)
        #expect((events.first?.detail?.count ?? 0) <= 301)
        #expect((events.last?.detail?.count ?? 0) <= 601)
        #expect(events.last?.detail?.hasSuffix("…") == true)
    }

    // MARK: Sessions

    @Test func connectedExpiresAfter300s() async throws {
        let (rpc, _, _, clock) = makeRPC()
        _ = try await initialize(rpc)
        clock.now += 299
        #expect(rpc.sessions.connectedClient(now: clock.now) == "claude-code 2.1")
        clock.now += 2
        #expect(rpc.sessions.connectedClient(now: clock.now) == nil)
    }

    @Test func unknownSessionCountsAsConnected() async throws {
        let (rpc, provider, log, clock) = makeRPC()
        let call = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#
        let r = await rpc.handle(request(body: call, session: "from-before-a-restart"))
        #expect(r.status == 200)
        #expect(r.header("Mcp-Session-Id") == "from-before-a-restart")
        #expect(rpc.sessions.connectedClient(now: clock.now) == "MCP client")
        #expect(provider.calls.last?.client == "MCP client")
        #expect(log.events.contains { $0.kind == .connect && $0.summary == "Session resumed" })
    }

    @Test func sessionsRememberClientsAndEnd() async throws {
        var s = MCPSessions()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let id = s.begin(client: "agent 1", now: now)
        #expect(s.touch(id, now: now + 10) == (client: "agent 1", isNew: false))
        // A server restart forgets live sessions but not who held each id.
        s.endAll()
        #expect(s.connectedClient(now: now + 10) == nil)
        #expect(s.touch(id, now: now + 20) == (client: "agent 1", isNew: true))
        let other = s.begin(client: "agent 2", now: now + 30)
        #expect(s.connectedClient(now: now + 40) == "agent 2")
        #expect(s.end(other) == "agent 2")
        #expect(s.end(other) == nil)
        #expect(s.connectedClient(now: now + 40) == "agent 1")
    }

    @Test func deleteEndsTheSession() async throws {
        let (rpc, _, log, clock) = makeRPC()
        let session = try await initialize(rpc)
        let r = await rpc.handle(request("DELETE", session: session))
        #expect(r.status == 200)
        #expect(String(decoding: r.body, as: UTF8.self) == "{}")
        #expect(log.events.last?.kind == .disconnect)
        #expect(log.events.last?.summary == "Session ended")
        #expect(rpc.sessions.connectedClient(now: clock.now) == nil)
    }

    // MARK: Log

    @Test func logTrimsItsFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorMCPLog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mcp.log")
        let log = MCPLog(fileURL: url, maxEvents: 50, maxFileBytes: 2_000)
        for i in 0..<100 { log.add(.call, client: "agent", "event \(i)", detail: "{\"n\":\(i)}") }
        await log.flushed()
        #expect(log.events.count == 50)
        #expect(log.events.last?.summary == "event 99")
        let data = try Data(contentsOf: url)
        #expect(data.count <= 2_000)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        #expect(lines.count > 1)
        for line in lines { #expect(JSONValue.decode(Data(line.utf8))?["summary"] != nil) }
        #expect(JSONValue.decode(Data(lines.last!.utf8))?["summary"]?.string == "event 99")
        #expect(JSONValue.decode(Data(lines.last!.utf8))?["kind"]?.string == "call")

        log.clearView()
        #expect(log.events.isEmpty)
        #expect(MCPLog.defaultFileURL.path.hasSuffix("Library/Logs/SubFloor/mcp.log"))
        #expect(MCPEvent.Kind.auth.displayName == "Refused")
        #expect(MCPEvent.Kind.allCases.map(\.displayName)
                == ["Server", "Connected", "Disconnected", "Tool call", "Result", "Error", "Refused"])
    }
}
