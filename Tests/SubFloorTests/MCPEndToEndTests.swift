import Foundation
import SubFloorCore
import Testing
import Transcription
@testable import SubFloor

/// A SubFloor MCP server for real agents (Claude Code, Codex, Hermes) to connect to, by hand. Skipped unless
/// `SUBFLOOR_MCP_E2E=1`. It serves the real tools over a demo-source model with its own defaults, bookmarks,
/// recordings and decode history (all temporary), so it never touches the owner's running SubFloor, its settings
/// or its port.
///
///     SUBFLOOR_MCP_E2E=1 swift test --skip-build --filter MCPEndToEndTests
///
/// - `SUBFLOOR_MCP_E2E_PORT`: the port (default 7899).
/// - `SUBFLOOR_MCP_E2E_TOKEN`: the bearer token (default: a new one).
/// - `SUBFLOOR_MCP_E2E_INFO`: where to write `{"url", "token"}` for the agents' configs (default
///   `$TMPDIR/subfloor-mcp-e2e.json`); the event log goes beside it as `mcp-e2e.log`.
/// - `SUBFLOOR_MCP_E2E_SECONDS`: how long to serve (default 300).
@MainActor
@Suite(.serialized)
struct MCPEndToEndTests {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test(.enabled(if: env["SUBFLOOR_MCP_E2E"] == "1", "set SUBFLOOR_MCP_E2E=1 to serve for agents"))
    func serveForAgents() async throws {
        let port = Int(Self.env["SUBFLOOR_MCP_E2E_PORT"] ?? "") ?? 7899
        try #require(port != MCPSettings.defaultPort, "7824 is the owner's SubFloor")
        let seconds = Double(Self.env["SUBFLOOR_MCP_E2E_SECONDS"] ?? "") ?? 300
        let token = Self.env["SUBFLOOR_MCP_E2E_TOKEN"].flatMap { $0.isEmpty ? nil : $0 } ?? MCPAuth.generateToken()
        let info = URL(fileURLWithPath: Self.env["SUBFLOOR_MCP_E2E_INFO"]
                       ?? FileManager.default.temporaryDirectory.appendingPathComponent("subfloor-mcp-e2e.json").path)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorE2E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let modelSuite = "SubFloorE2E-\(UUID().uuidString)", serverSuite = "SubFloorE2E-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: dir)
            for suite in [modelSuite, serverSuite] { UserDefaults.standard.removePersistentDomain(forName: suite) }
        }
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: UserDefaults(suiteName: modelSuite)!,
                         apiKeyStore: MemoryAPIKeyStore(),
                         openRSP: { throw CancellationError() }, rspOpenTimeout: .seconds(10),
                         decodeHistoryFolder: dir.appendingPathComponent("decodes"))
        defer { m.shutdown() }   // before the folder goes
        m.recording.folderPath = dir.appendingPathComponent("rec").path
        m.volume = 0   // the owner's SubFloor may be playing
        m.useSource(.synthetic)
        if !m.isRunning { print("E2E: the demo radio did not start (no audio device?); serving anyway") }

        let tools = SubFloorTools(model: m)
        let log = MCPLog(fileURL: info.deletingLastPathComponent().appendingPathComponent("mcp-e2e.log"))
        let server = MCPServer(provider: tools, defaults: UserDefaults(suiteName: serverSuite)!,
                               tokenStore: MemoryAPIKeyStore(key: token), log: log)
        tools.connectedClients = { [weak server] in server?.connectedClients ?? [] }
        await server.apply(MCPSettings(enabled: true, port: port))
        defer { server.stop() }
        let bound = try #require(server.boundPort, "the server did not start: \(server.state)")
        let url = "http://127.0.0.1:\(bound)/mcp"
        let json = JSONValue.object(["url": .string(url), "token": .string(server.token)])
        try json.encoded().write(to: info, options: .atomic)
        print("E2E: serving \(url) for \(Int(seconds)) s; url and token in \(info.path)")

        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try await Task.sleep(for: .milliseconds(250)) }
        for e in log.events {
            print("E2E log: \(e.kind.rawValue) \(e.client ?? "-") \(e.summary)")
        }
        await log.flushed()
    }
}
