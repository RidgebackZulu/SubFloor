import Foundation

/// How one agent is pointed at SubFloor: the text to paste, where it goes, and for some a command SubFloor can run.
struct AgentSnippet: Identifiable {
    var id: String
    var name: String
    /// One line on where the text goes and what to do after.
    var whereItGoes: String
    /// Ready to paste, with the URL and token filled in.
    var text: String
    /// A second block that goes somewhere else (a file, say), with its own Copy button.
    var extra: Extra?
    /// The agent asks for the token itself, so the window offers Copy Token.
    var asksForToken = false
    /// The agent's own "add MCP server" command, when it takes the token without asking for it.
    var install: AgentInstall?

    struct Extra {
        /// The Copy button's title, naming where the block goes.
        var copyLabel: String
        var text: String
    }
}

/// The commands that add SubFloor to an agent, run in order and without a shell.
struct AgentInstall: Equatable, Sendable {
    struct Step: Equatable, Sendable {
        var arguments: [String]
        /// Written to the command's standard input, then closed.
        var stdin: String?
        /// A failure is ignored and its output left out (removing an entry that may not be there).
        var mayFail = false
    }

    /// A bare name ("claude") found by `AgentInstaller.locate`, or an absolute path.
    var executable: String
    var steps: [Step]
}

/// The Setup tab's "Connect an agent" list. Each format follows that client's documentation as of 2026-10-31;
/// where the documentation was unclear, `whereItGoes` says to check it.
enum AgentSnippets {
    /// Shown in place of the token while the Token field is hidden.
    static let mask = "••••••••"

    static func all(url: String, token: String) -> [AgentSnippet] {
        let bearer = "Authorization: Bearer \(token)"
        return [
            AgentSnippet(
                id: "claude-code", name: "Claude Code",
                whereItGoes: "Click Add, or run in Terminal: SubFloor joins every project (~/.claude.json). If you "
                    + "added it before (a new token, say), run claude mcp remove --scope user subfloor first; Add does. "
                    + "Restart Claude Code, or /mcp to reconnect.",
                text: #"claude mcp add --transport http --scope user subfloor \#(url) --header "\#(bearer)""#,
                install: AgentInstall(executable: "claude", steps: [
                    // `claude mcp add` refuses a name it already has.
                    .init(arguments: ["mcp", "remove", "--scope", "user", "subfloor"], mayFail: true),
                    .init(arguments: ["mcp", "add", "--transport", "http", "--scope", "user", "subfloor", url,
                                      "--header", bearer]),
                ])),
            AgentSnippet(
                id: "claude-code-plugin", name: "Claude Code plugin",
                whereItGoes: "Paste the two /plugin lines into Claude Code one at a time, pressing Return after "
                    + "each. Add the ~/.zshenv lines to that file in a "
                    + "text editor (not at a prompt), then start Claude Code from a new Terminal. The plugin brings "
                    + "the SubFloor skill too.",
                text: """
                    /plugin marketplace add RidgebackZulu/SubFloor
                    /plugin install subfloor@subfloor
                    """,
                extra: .init(copyLabel: "Copy ~/.zshenv lines", text: """
                    export SUBFLOOR_MCP_URL=\(url)
                    export SUBFLOOR_MCP_TOKEN=\(token)
                    """)),
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
                whereItGoes: "Run in Terminal. Answer yes to authentication, and when it asks for the API key / "
                    + "Bearer token, paste the token (Copy Token). Then /reload-mcp in Hermes, or start a new session.",
                text: "hermes mcp add subfloor --url \(url) --auth header",
                asksForToken: true),
            AgentSnippet(
                id: "hermes-config", name: "Hermes (config.yaml)",
                whereItGoes: "Add the block to ~/.hermes/config.yaml and the .env line to ~/.hermes/.env, then "
                    + "hermes mcp test subfloor.",
                text: """
                    mcp_servers:
                      subfloor:
                        url: "\(url)"
                        headers:
                          Authorization: "Bearer ${MCP_SUBFLOOR_API_KEY}"
                    """,
                extra: .init(copyLabel: "Copy ~/.hermes/.env line", text: "MCP_SUBFLOOR_API_KEY=\(token)")),
            AgentSnippet(
                id: "codex", name: "Codex CLI",
                whereItGoes: "~/.codex/config.toml. Restart Codex sessions after the change. Codex asks before each "
                    + "tool that changes the radio, and codex exec cancels them: add default_tools_approval_mode = "
                    + "\"approve\" to the block to allow them. tool_timeout_sec gives a 60 s listen and its "
                    + "transcript time to finish.",
                text: """
                    [mcp_servers.subfloor]
                    url = "\(url)"
                    http_headers = { "Authorization" = "Bearer \(token)" }
                    tool_timeout_sec = 120
                    """),
            AgentSnippet(
                id: "gemini", name: "Gemini CLI",
                whereItGoes: "Run in Terminal, or click Add: SubFloor goes in ~/.gemini/settings.json for every "
                    + "project. Restart Gemini CLI; /mcp shows it.",
                text: #"gemini mcp add --scope user --transport http --header "\#(bearer)" subfloor \#(url)"#,
                // `gemini mcp add` replaces an entry of the same name, so no remove first.
                install: AgentInstall(executable: "gemini", steps: [
                    .init(arguments: ["mcp", "add", "--scope", "user", "--transport", "http", "--header", bearer,
                                      "subfloor", url]),
                ])),
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
