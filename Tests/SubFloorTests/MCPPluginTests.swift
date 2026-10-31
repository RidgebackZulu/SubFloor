import Foundation
import SubFloorCore
import Testing
import Transcription
@testable import SubFloor

/// The Claude Code / Hermes plugin in `plugins/subfloor`: its tool reference documents every tool the server
/// offers (and nothing else), every argument of each, and its config files point at the right server.
@MainActor
struct MCPPluginTests {
    /// The repository's root: three folders up from this file (`Tests/SubFloorTests/`).
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let plugin = root.appendingPathComponent("plugins/subfloor")

    private func text(_ path: String, in base: URL = plugin) throws -> String {
        try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
    }

    private func json(_ path: String, in base: URL = plugin) throws -> JSONValue {
        try #require(JSONValue.decode(Data(text(path, in: base).utf8)), "\(path) is not JSON")
    }

    private func makeTools() -> SubFloorTools {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = AppModel(bookmarkStore: BookmarkStore(url: dir.appendingPathComponent("bookmarks.json")),
                         defaults: UserDefaults(suiteName: UUID().uuidString)!,
                         openRSP: { throw CancellationError() }, rspOpenTimeout: .seconds(10),
                         decodeHistoryFolder: dir.appendingPathComponent("decodes"))
        return SubFloorTools(model: m)
    }

    /// The "### `name`" sections of tools.md: each heading's name and the text under it.
    private func sections(_ md: String) -> [(heading: String, body: String)] {
        var out: [(String, String)] = []
        for line in md.components(separatedBy: "\n") {
            if line.hasPrefix("#") {
                out.append((line, ""))
            } else if !out.isEmpty {
                out[out.count - 1].1 += line + "\n"
            }
        }
        return out.filter { $0.0.hasPrefix("### ") }
    }

    @Test func pluginDocumentsEveryTool() throws {
        let md = try text("skills/subfloor-radio/references/tools.md")
        let tools = makeTools().tools
        let found = sections(md)
        // Every "###" heading is one tool, written "### `name`", once.
        let names = found.map { s -> String in
            let h = s.heading.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return h.hasPrefix("`") && h.hasSuffix("`") && h.count > 2 ? String(h.dropFirst().dropLast()) : "(\(h))"
        }
        #expect(names.count == Set(names).count, "a tool is documented twice")
        #expect(Set(names) == Set(tools.map(\.name)))
        #expect(names.count == tools.count)
        // And every argument of each tool is named in its section.
        for tool in tools {
            guard let i = names.firstIndex(of: tool.name) else { continue }
            for arg in tool.inputSchema["properties"]?.object?.keys.sorted() ?? [] {
                #expect(found[i].body.contains("`\(arg)`"), "\(tool.name): argument \(arg) is not documented")
            }
        }
    }

    @Test func mcpJsonPointsAtTheServer() throws {
        let server = try #require(try json(".mcp.json")["mcpServers"]?["subfloor"])
        #expect(server["type"]?.string == "http")
        let url = try #require(server["url"]?.string)
        #expect(url.contains("7824"))
        #expect(url == "${SUBFLOOR_MCP_URL:-http://127.0.0.1:\(MCPSettings.defaultPort)/mcp}")
        #expect(server["headers"]?["Authorization"]?.string == "Bearer ${SUBFLOOR_MCP_TOKEN}")
    }

    @Test func manifestsNameThePlugin() throws {
        #expect(try json(".claude-plugin/plugin.json")["name"]?.string == "subfloor")
        #expect(try json("plugin.json")["name"]?.string == "subfloor")
        let market = try json(".claude-plugin/marketplace.json", in: Self.root)
        #expect(market["name"]?.string == "subfloor")
        #expect(market["owner"]?["name"]?.string == "RidgebackZulu")
        let entry = try #require(market["plugins"]?.array?.first)
        #expect(market["plugins"]?.array?.count == 1)
        #expect(entry["name"]?.string == "subfloor")
        #expect(entry["source"]?.string == "./plugins/subfloor")
        // The snippet's `/plugin install subfloor@subfloor` is plugin@marketplace.
        let snippet = try #require(AgentSnippets.all(url: "u", token: "t").first { $0.id == "claude-code-plugin" })
        #expect(snippet.text.contains("/plugin install subfloor@subfloor"))
        let skill = try text("skills/subfloor-radio/SKILL.md")
        #expect(skill.hasPrefix("---\nname: subfloor-radio\n"))
    }
}
