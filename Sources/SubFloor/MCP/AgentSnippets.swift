import Foundation

/// How one agent is pointed at SubFloor: the text to paste, where it goes, and for some a command SubFloor can run.
struct AgentSnippet: Identifiable {
    var id: String
    var name: String
    /// One line on where the text goes and what to do after.
    var whereItGoes: String
    /// Ready to paste, with the URL and token filled in.
    var text: String
    /// The agent's own "add MCP server" command, when it takes the token without asking for it.
    var install: AgentInstall?
}

/// A command that adds SubFloor to an agent, run without a shell.
struct AgentInstall: Equatable, Sendable {
    /// A bare name ("claude") found by `AgentInstaller.locate`, or an absolute path.
    var executable: String
    var arguments: [String]
    /// Written to the command's standard input, then closed.
    var stdin: String?
}

/// The Setup tab's "Connect an agent" list. Each format follows that client's documentation as of 2026-10-31;
/// where the documentation was unclear, `whereItGoes` says to check it.
enum AgentSnippets {
    static func all(url: String, token: String) -> [AgentSnippet] {
        let bearer = "Authorization: Bearer \(token)"
        return [
            AgentSnippet(
                id: "claude-code", name: "Claude Code",
                whereItGoes: "Run in Terminal, or click Add: SubFloor joins every project (~/.claude.json). "
                    + "Restart Claude Code, or /mcp to reconnect.",
                text: #"claude mcp add --transport http --scope user subfloor \#(url) --header "\#(bearer)""#,
                install: AgentInstall(executable: "claude",
                                      arguments: ["mcp", "add", "--transport", "http", "--scope", "user", "subfloor", url,
                                                  "--header", bearer])),
            AgentSnippet(
                id: "claude-code-plugin", name: "Claude Code plugin",
                whereItGoes: "Run the first two lines once; put the exports in ~/.zshenv so Claude Code sees them, "
                    + "then restart it. The plugin brings the SubFloor skill too.",
                text: """
                    claude plugin marketplace add RidgebackZulu/SubFloor
                    claude plugin install subfloor@subfloor
                    export SUBFLOOR_MCP_URL=\(url)
                    export SUBFLOOR_MCP_TOKEN=\(token)
                    """),
            AgentSnippet(
                id: "claude-desktop", name: "Claude Desktop",
                whereItGoes: "~/Library/Application Support/Claude/claude_desktop_config.json (Settings › Developer › "
                    + "Edit Config), merged with any servers there. Needs Node (npx). Quit and reopen Claude Desktop. "
                    + "Its Connectors can't reach a server on this Mac.",
                text: """
                    {
                      "mcpServers": {
                        "subfloor": {
                          "command": "npx",
                          "args": [
                            "-y", "mcp-remote", "\(url)",
                            "--allow-http",
                            "--header", "Authorization:${SUBFLOOR_AUTH}"
                          ],
                          "env": { "SUBFLOOR_AUTH": "Bearer \(token)" }
                        }
                      }
                    }
                    """),
            AgentSnippet(
                id: "hermes", name: "Hermes Agent",
                whereItGoes: "Run the first line in Terminal. Answer yes to authentication and paste the token when "
                    + "asked. Then /reload-mcp in Hermes, or start a new session.",
                text: """
                    hermes mcp add subfloor --url \(url) --auth header
                    # When asked for the API key / Bearer token, paste:
                    # \(token)
                    """),
            AgentSnippet(
                id: "hermes-config", name: "Hermes (config.yaml)",
                whereItGoes: "Add the first part to ~/.hermes/.env and the second to ~/.hermes/config.yaml, then "
                    + "hermes mcp test subfloor.",
                text: """
                    # ~/.hermes/.env
                    MCP_SUBFLOOR_API_KEY=\(token)

                    # ~/.hermes/config.yaml
                    mcp_servers:
                      subfloor:
                        url: "\(url)"
                        headers:
                          Authorization: "Bearer ${MCP_SUBFLOOR_API_KEY}"
                    """),
            AgentSnippet(
                id: "codex", name: "Codex CLI",
                whereItGoes: "~/.codex/config.toml. Restart Codex sessions after the change.",
                text: """
                    [mcp_servers.subfloor]
                    url = "\(url)"
                    http_headers = { "Authorization" = "Bearer \(token)" }
                    """),
            AgentSnippet(
                id: "gemini", name: "Gemini CLI",
                whereItGoes: "Run in Terminal, or click Add: SubFloor goes in ~/.gemini/settings.json for every "
                    + "project. Restart Gemini CLI; /mcp shows it.",
                text: #"gemini mcp add --scope user --transport http --header "\#(bearer)" subfloor \#(url)"#,
                install: AgentInstall(executable: "gemini",
                                      arguments: ["mcp", "add", "--scope", "user", "--transport", "http",
                                                  "--header", bearer, "subfloor", url])),
            AgentSnippet(
                id: "cursor", name: "Cursor",
                whereItGoes: "~/.cursor/mcp.json (every project) or .cursor/mcp.json in one, merged with any servers "
                    + "there. Turn it on in Settings › Tools & MCP.",
                text: jsonServers("mcpServers", url: url, token: token)),
            AgentSnippet(
                id: "vscode", name: "VS Code",
                whereItGoes: "Copilot agent mode: Command Palette › MCP: Open User Configuration (or .vscode/mcp.json "
                    + "in a workspace), then Start on the subfloor entry.",
                text: jsonServers("servers", url: url, token: token, type: "http")),
            AgentSnippet(
                id: "windsurf", name: "Windsurf",
                whereItGoes: "~/.codeium/windsurf/mcp_config.json (Cascade › MCPs › View raw config), then refresh. "
                    + "The file has moved between versions: check your client's docs.",
                text: jsonServers("mcpServers", url: url, token: token, urlKey: "serverUrl")),
            AgentSnippet(
                id: "lm-studio", name: "LM Studio",
                whereItGoes: "LM Studio 0.3.17 or later: Program tab › Install › Edit mcp.json (~/.lmstudio/mcp.json; "
                    + "check your client's docs).",
                text: jsonServers("mcpServers", url: url, token: token)),
            AgentSnippet(
                id: "goose", name: "Goose",
                whereItGoes: "~/.config/goose/config.yaml, under extensions:. Restart the Goose session.",
                text: """
                    extensions:
                      subfloor:
                        name: subfloor
                        type: streamable_http
                        uri: \(url)
                        enabled: true
                        timeout: 300
                        headers:
                          Authorization: "Bearer \(token)"
                    """),
            AgentSnippet(
                id: "other", name: "Any other client",
                whereItGoes: "Any MCP client running on this Mac that speaks Streamable HTTP. Cloud connectors "
                    + "(Claude.ai, ChatGPT) can't reach 127.0.0.1.",
                text: """
                    URL: \(url)
                    Transport: Streamable HTTP
                    Header: \(bearer)
                    """),
        ]
    }

    /// `{ "<root>": { "subfloor": { ["type",] "<urlKey>": url, "headers": { "Authorization": … } } } }`.
    private static func jsonServers(_ root: String, url: String, token: String, type: String? = nil,
                                    urlKey: String = "url") -> String {
        let typeLine = type.map { "\n      \"type\": \"\($0)\"," } ?? ""
        return """
            {
              "\(root)": {
                "subfloor": {\(typeLine)
                  "\(urlKey)": "\(url)",
                  "headers": { "Authorization": "Bearer \(token)" }
                }
              }
            }
            """
    }
}
