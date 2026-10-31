import AppKit
import SwiftUI
import Testing
@testable import SubFloor

/// The MCP button and window: the agent snippets, the one-click installs, the display strings, and the
/// button drawn in each state.
@MainActor
@Suite struct MCPUITests {
    static let url = "http://127.0.0.1:7900/mcp"

    @Test func snippetsFillUrlAndToken() {
        let snippets = AgentSnippets.all(url: Self.url, token: "tok123")
        #expect(snippets.map(\.name) == [
            "Claude Code", "Claude Code plugin", "Claude Desktop", "Hermes Agent", "Hermes (config.yaml)", "Codex CLI",
            "Gemini CLI", "Cursor", "VS Code", "Windsurf", "LM Studio", "Goose", "Any other client",
        ])
        #expect(Set(snippets.map(\.id)).count == 13)
        for s in snippets {
            let all = s.text + "\n" + (s.extra?.text ?? "")
            #expect(all.contains(Self.url), "\(s.name)")
            switch s.name {
            case "Claude Code plugin":
                // Typed in Claude Code; the token only in the ~/.zshenv lines, never run in a shell.
                #expect(!s.text.contains("tok123"))
                #expect(s.extra?.text.contains("SUBFLOOR_MCP_TOKEN=tok123") == true)
            case "Hermes Agent":
                // Hermes asks for the token itself: the text is the command alone.
                #expect(s.text == "hermes mcp add subfloor --url \(Self.url) --auth header")
                #expect(s.asksForToken)
            default:
                #expect(all.contains("tok123"), "\(s.name)")
            }
            #expect(!s.whereItGoes.isEmpty, "\(s.name)")
        }
    }

    @Test func displayMasksTheTokenUntilShown() throws {
        let snippets = AgentSnippets.all(url: Self.url, token: "tok123")
        let claude = try #require(snippets.first { $0.name == "Claude Code" })
        let hidden = MCPWindow.displayed(claude.text, token: "tok123", showToken: false)
        #expect(!hidden.contains("tok123"))
        #expect(hidden.contains(AgentSnippets.mask))
        #expect(hidden.contains(Self.url))
        #expect(MCPWindow.displayed(claude.text, token: "tok123", showToken: true) == claude.text)
        #expect(MCPWindow.displayed("Added server, Bearer tok123", token: "tok123", showToken: false)
                == "Added server, Bearer \(AgentSnippets.mask)")
    }

    @Test func claudeCodeInstallIsNonInteractive() throws {
        let snippets = AgentSnippets.all(url: Self.url, token: "tok123")
        let claude = try #require(snippets.first { $0.name == "Claude Code" }?.install)
        #expect(claude.executable == "claude")
        // Removes any earlier entry (after New Token, add refuses an existing name), then adds.
        #expect(claude.steps == [
            AgentInstall.Step(arguments: ["mcp", "remove", "--scope", "user", "subfloor"], mayFail: true),
            AgentInstall.Step(arguments: ["mcp", "add", "--transport", "http", "--scope", "user", "subfloor", Self.url,
                                          "--header", "Authorization: Bearer tok123"]),
        ])
        // Gemini's add replaces an existing entry of the same name.
        let gemini = try #require(snippets.first { $0.name == "Gemini CLI" }?.install)
        #expect(gemini.executable == "gemini")
        #expect(gemini.steps == [
            AgentInstall.Step(arguments: ["mcp", "add", "--scope", "user", "--transport", "http",
                                          "--header", "Authorization: Bearer tok123", "subfloor", Self.url]),
        ])
        // Only clients whose own add command takes the token without asking get a one-click Add.
        #expect(snippets.filter { $0.install != nil }.map(\.name) == ["Claude Code", "Gemini CLI"])
    }

    @Test func installerRunsWithoutAShell() async {
        let echo = await AgentInstaller.run(AgentInstall(executable: "/bin/cat",
                                                         steps: [.init(arguments: [], stdin: "hello; $(rm x)")]))
        #expect(echo.ok)
        #expect(echo.output == "hello; $(rm x)")
        let failing = await AgentInstaller.run(AgentInstall(executable: "/usr/bin/false", steps: [.init(arguments: [])]))
        #expect(!failing.ok)
        let missing = await AgentInstaller.run(AgentInstall(executable: "no-such-agent-cli", steps: [.init(arguments: [])]))
        #expect(!missing.ok)
        #expect(missing.output.contains("not found"))
        #expect(AgentInstaller.locate("no-such-agent-cli") == nil)
    }

    @Test func installerStepsMayFailOrStop() async {
        // A step allowed to fail is skipped quietly; a later failure stops the run before the next step.
        let tolerated = await AgentInstaller.run(AgentInstall(executable: "/bin/sh", steps: [
            .init(arguments: ["-c", "echo gone; exit 1"], mayFail: true),
            .init(arguments: ["-c", "echo added"]),
        ]))
        #expect(tolerated.ok)
        #expect(tolerated.output == "added")
        let stopped = await AgentInstaller.run(AgentInstall(executable: "/bin/sh", steps: [
            .init(arguments: ["-c", "echo first; exit 2"]),
            .init(arguments: ["-c", "echo second"]),
        ]))
        #expect(!stopped.ok)
        #expect(stopped.output == "first")
    }

    @Test func tooltipsAndStatusLines() {
        #expect(MCPButton.tooltip(for: .off, port: 7824) == "MCP server off: click to let AI agents use SubFloor")
        #expect(MCPButton.tooltip(for: .failed("Port 7824 is in use"), port: 7824)
                == "MCP server could not start: port 7824 is in use")
        #expect(MCPButton.tooltip(for: .listening, port: 7824) == "MCP server listening, no agent connected")
        #expect(MCPButton.tooltip(for: .connected(client: "Claude Code 2.1"), port: 7824) == "Claude Code 2.1 connected")

        let url = "http://127.0.0.1:7824/mcp"
        #expect(MCPWindow.statusLine(for: .off, url: url) == "● Off")
        #expect(MCPWindow.statusLine(for: .listening, url: url)
                == "● Listening on http://127.0.0.1:7824/mcp — no agent connected")
        #expect(MCPWindow.statusLine(for: .connected(client: "Claude Code 2.1"), url: url)
                == "● Connected — Claude Code 2.1")
        #expect(MCPWindow.statusLine(for: .failed("Port 7824 is in use"), url: url) == "● Could not start: port in use")
        #expect(MCPWindow.statusLine(for: .failed("Could not start on port 7824"), url: url)
                == "● Could not start on port 7824")
    }

    @Test func buttonRendersEachState() throws {
        let states: [MCPState] = [.off, .failed("Port 7824 is in use"), .listening, .connected(client: "Claude Code 2.1")]
        for state in states {
            let host = NSHostingView(rootView: MCPPill(state: state, pulse: 0).padding(10))
            host.frame = NSRect(x: 0, y: 0, width: 94, height: 44)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            var drawn = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                    if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { drawn += 1 }
                }
            }
            #expect(drawn > 50, "\(state)")
        }
    }
}
