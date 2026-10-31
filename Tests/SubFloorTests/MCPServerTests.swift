import Foundation
import Network
import Security
import Testing
import Transcription
@testable import SubFloor

/// The MCP server over a real loopback socket: settings, the token, start, stop and a busy port. Every server
/// binds an ephemeral port (`port: 0`) and is stopped before the test ends.
@MainActor
@Suite(.serialized)
struct MCPServerTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MCPServerTests-\(UUID().uuidString)")!
    }

    private func makeServer(defaults: UserDefaults? = nil, store: APIKeyStore = MemoryAPIKeyStore()) -> MCPServer {
        MCPServer(provider: EmptyToolProvider(), defaults: defaults ?? makeDefaults(), tokenStore: store,
                  log: MCPLog(fileURL: nil))
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private static let initializeBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":"#
        + #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}"#

    /// POSTs `body` to the server's `/mcp`; returns the status, the reply and its session id.
    private func post(_ server: MCPServer, _ body: String, token: String? = nil,
                      sessionId: String? = nil) async throws -> (Int, JSONValue?, String?) {
        let port = try #require(server.boundPort)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token ?? server.token)", forHTTPHeaderField: "Authorization")
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        return (http.statusCode, JSONValue.decode(data), http.value(forHTTPHeaderField: "Mcp-Session-Id"))
    }

    /// Waits up to `seconds` for `condition`.
    private func waitFor(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Set from a Network callback, read by the test.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var set = false
        var value: Bool { lock.withLock { set } }
        func raise() { lock.withLock { set = true } }
    }

    /// A loopback port free right now: bound by a throwaway listener, which is cancelled and gone before
    /// this returns.
    private func freePort() async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let throwaway = try NWListener(using: parameters)
        let cancelled = Flag()
        throwaway.stateUpdateHandler = { if case .cancelled = $0 { cancelled.raise() } }
        throwaway.newConnectionHandler = { $0.cancel() }
        throwaway.start(queue: DispatchQueue(label: "MCPServerTests.freePort"))
        #expect(await waitFor { throwaway.port != nil && throwaway.port?.rawValue != 0 })
        let port = Int(try #require(throwaway.port).rawValue)
        throwaway.cancel()
        #expect(await waitFor { cancelled.value })
        return port
    }

    @Test func servesOverLoopback() async throws {
        let server = makeServer()
        defer { server.stop() }
        await server.apply(MCPSettings(enabled: true, port: 0))
        #expect(server.state == .listening)
        #expect(server.boundPort != nil)

        let (status, reply, sessionId) = try await post(server, Self.initializeBody)
        #expect(status == 200)
        #expect(reply?["result"]?["serverInfo"]?["name"]?.string == "subfloor")
        let id = try #require(sessionId)

        let pulse = server.pulse
        let (listStatus, list, _) = try await post(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                                                   sessionId: id)
        #expect(listStatus == 200)
        #expect(list?["result"]?["tools"]?.array == [])
        #expect(server.state == .connected(client: "test 1.0"))
        #expect(server.connectedClients == ["test 1.0"])
        #expect(server.pulse == pulse + 1)
        #expect(server.log.events.contains { $0.kind == .server && $0.summary.hasPrefix("Listening on") })
    }

    @Test func malformedRequestGetsAnErrorAndAClose() async throws {
        let server = makeServer()
        defer { server.stop() }
        await server.apply(MCPSettings(enabled: true, port: 0))
        let port = try #require(server.boundPort)

        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        connection.start(queue: DispatchQueue(label: "MCPServerTests.client"))
        connection.send(content: Data("POST /mcp HTTP/1.1\r\nContent-Length: nope\r\n\r\n".utf8),
                        completion: .idempotent)
        // Read until the server closes the connection.
        var reply = Data()
        while true {
            let (chunk, done) = await withCheckedContinuation { (c: CheckedContinuation<(Data?, Bool), Never>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                    c.resume(returning: (data, complete || error != nil))
                }
            }
            if let chunk { reply.append(chunk) }
            if done { break }
        }
        let text = String(decoding: reply, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 400 "))
        #expect(text.contains("Connection: close"))
    }

    @Test func busyPortFailsCleanly() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let blocker = try NWListener(using: parameters)
        blocker.newConnectionHandler = { $0.cancel() }
        blocker.start(queue: DispatchQueue(label: "MCPServerTests.blocker"))
        defer { blocker.cancel() }
        #expect(await waitFor { blocker.port != nil && blocker.port?.rawValue != 0 })
        let port = Int(try #require(blocker.port).rawValue)

        let defaults = makeDefaults()
        let server = makeServer(defaults: defaults)
        defer { server.stop() }
        await server.apply(MCPSettings(enabled: true, port: port))
        #expect(server.state == .failed("Port \(port) is in use"))
        #expect(server.boundPort == nil)
        #expect(server.log.events.contains {
            $0.kind == .error && $0.summary.hasPrefix("Could not start on port \(port): ")
        })
        #expect(MCPSettings.load(defaults) == MCPSettings(enabled: true, port: port))

        // Once the port is free, applying again starts it (retried while the blocker lets go).
        blocker.cancel()
        let deadline = Date().addingTimeInterval(10)
        repeat {
            try await Task.sleep(for: .milliseconds(100))
            await server.apply(MCPSettings(enabled: true, port: port))
        } while server.state != .listening && Date() < deadline
        #expect(server.state == .listening)
        #expect(server.boundPort == UInt16(port))
    }

    @Test func refusesPortsOutsideTheRange() async {
        let server = makeServer()
        defer { server.stop() }
        await server.apply(MCPSettings(enabled: true, port: 80))
        #expect(server.state == .failed("Port 80 is not allowed (1024–65535)"))
        await server.apply(MCPSettings(enabled: true, port: 70_000))
        #expect(server.state == .failed("Port 70000 is not allowed (1024–65535)"))
        #expect(server.settings.port == 70_000)
        await server.apply(MCPSettings(enabled: false, port: 7824))
        #expect(server.state == .off)
    }

    @Test func newTokenRefusesTheOldOne() async throws {
        let store = MemoryAPIKeyStore()
        let server = makeServer(store: store)
        defer { server.stop() }
        await server.apply(MCPSettings(enabled: true, port: 0))
        let old = server.token
        let (status, _, _) = try await post(server, Self.initializeBody)
        #expect(status == 200)

        server.newToken()
        #expect(server.token != old)
        #expect(server.token.count == 43)
        #expect(store.load() == server.token)
        #expect(server.log.events.contains { $0.kind == .server && $0.summary.contains("token") })
        #expect(await waitFor { server.boundPort != nil && server.state == .listening })

        let (refused, _, _) = try await post(server, Self.initializeBody, token: old)
        #expect(refused == 401)
        #expect(server.log.events.contains { $0.kind == .auth })
        let (accepted, _, _) = try await post(server, Self.initializeBody)
        #expect(accepted == 200)
    }

    @Test func newTokenKeepsAFixedPort() async throws {
        let port = try await freePort()
        let server = makeServer()
        defer { server.stop() }
        await server.apply(MCPSettings(enabled: true, port: port))
        #expect(server.state == .listening)
        #expect(server.boundPort == UInt16(port))
        let (status, _, _) = try await post(server, Self.initializeBody)
        #expect(status == 200)

        server.newToken()
        #expect(await waitFor { server.boundPort != nil || { if case .failed = server.state { true } else { false } }() })
        #expect(server.state == .listening)
        #expect(server.boundPort == UInt16(port))
        let (accepted, _, _) = try await post(server, Self.initializeBody)
        #expect(accepted == 200)
    }

    @Test func stopThenApplyRebindsTheSamePort() async throws {
        let port = try await freePort()
        let other = try await freePort()
        let server = makeServer()
        defer { server.stop() }
        await server.apply(MCPSettings(enabled: true, port: port))
        #expect(server.boundPort == UInt16(port))
        let (first, _, _) = try await post(server, Self.initializeBody)   // an agent holds a connection open
        #expect(first == 200)

        server.stop()
        await server.apply(MCPSettings(enabled: true, port: port))
        #expect(server.state == .listening)
        #expect(server.boundPort == UInt16(port))

        let (second, _, _) = try await post(server, Self.initializeBody)
        #expect(second == 200)
        await server.apply(MCPSettings(enabled: false, port: port))
        await server.apply(MCPSettings(enabled: true, port: port))
        #expect(server.state == .listening)
        #expect(server.boundPort == UInt16(port))

        // A port change there and back.
        await server.apply(MCPSettings(enabled: true, port: other))
        #expect(server.boundPort == UInt16(other))
        await server.apply(MCPSettings(enabled: true, port: port))
        #expect(server.state == .listening)
        #expect(server.boundPort == UInt16(port))
        let (status, _, _) = try await post(server, Self.initializeBody)
        #expect(status == 200)
    }

    @Test func offByDefaultAndPersists() async throws {
        let defaults = makeDefaults()
        let fresh = makeServer(defaults: defaults)
        #expect(fresh.settings == MCPSettings())
        #expect(fresh.settings.enabled == false)
        #expect(fresh.settings.port == 7824)
        #expect(fresh.state == .off)
        #expect(MCPSettings(port: 7824).url == "http://127.0.0.1:7824/mcp")

        await fresh.apply(MCPSettings(enabled: true, port: 0))
        fresh.stop()
        #expect(fresh.state == .off)
        #expect(fresh.boundPort == nil)

        let again = makeServer(defaults: defaults)
        #expect(again.settings == MCPSettings(enabled: true, port: 0))
        #expect(again.state == .off)   // a new server waits for apply
        let stored = try #require(defaults.data(forKey: "mcp"))
        #expect(JSONValue.decode(stored)?["enabled"]?.bool == true)
    }

    @Test func settingsReadMissingFieldsAsDefaults() {
        let defaults = makeDefaults()
        defaults.set(Data(#"{"enabled":true}"#.utf8), forKey: "mcp")
        #expect(MCPSettings.load(defaults) == MCPSettings(enabled: true, port: 7824))
        defaults.set(Data("junk".utf8), forKey: "mcp")
        #expect(MCPSettings.load(defaults) == MCPSettings())
    }

    /// A token store whose reads are scripted, counting every read and save.
    private final class ScriptedTokenStore: APIKeyStore {
        var result: APIKeyLoadResult
        private(set) var reads = 0
        private(set) var saved: [String] = []
        init(_ result: APIKeyLoadResult) { self.result = result }
        func load() -> String? {
            if case .found(let key) = loadResult() { return key }
            return nil
        }
        func loadResult() -> APIKeyLoadResult {
            reads += 1
            return result
        }
        func save(_ key: String) throws { saved.append(key) }
        func remove() throws {}
    }

    @Test func theKeychainIsNotTouchedWhileOff() async {
        let store = ScriptedTokenStore(.failed(errSecAuthFailed))
        let server = makeServer(store: store)
        await server.apply(MCPSettings(enabled: false, port: 0))
        #expect(store.reads == 0)
        #expect(store.saved.isEmpty)
        #expect(server.state == .off)
    }

    @Test func anUnreadableTokenIsNotReplaced() async {
        let store = ScriptedTokenStore(.failed(errSecAuthFailed))
        let server = makeServer(store: store)
        defer { server.stop() }
        await server.apply(MCPSettings(enabled: true, port: 0))
        #expect(store.saved.isEmpty)
        #expect(server.state == .failed("Could not read the token from the Keychain"))
        #expect(server.boundPort == nil)
        #expect(server.log.events.contains { $0.kind == .error && $0.summary.contains("Keychain") })
        // Readable again (the owner allowed access): the saved token is used, still not replaced.
        store.result = .found("saved-token")
        await server.apply(MCPSettings(enabled: true, port: 0))
        #expect(server.boundPort != nil)
        #expect(server.token == "saved-token")
        #expect(store.saved.isEmpty)
    }

    @Test func aMissingTokenIsCreatedOnFirstStart() async {
        let store = ScriptedTokenStore(.notFound)
        let server = makeServer(store: store)
        defer { server.stop() }
        #expect(store.saved.isEmpty)
        await server.apply(MCPSettings(enabled: true, port: 0))
        #expect(store.saved.count == 1)
        #expect(server.token.count == 43)
        #expect(store.saved.first == server.token)
        #expect(server.boundPort != nil)
    }

    @Test func tokenSurvivesRestart() {
        let store = MemoryAPIKeyStore()
        let first = makeServer(store: store)
        #expect(first.token.isEmpty)   // read only when needed
        #expect(first.loadToken())
        #expect(first.token.count == 43)
        #expect(store.load() == first.token)
        let second = makeServer(store: store)
        #expect(second.loadToken())
        #expect(second.token == first.token)
    }
}
