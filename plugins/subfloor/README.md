# SubFloor plugin

Connects AI agents to the [SubFloor](https://github.com/RidgebackZulu/SubFloor) receiver's MCP server and adds
the `subfloor-radio` skill: how to work the radio well with SubFloor's tools (tune, listen, check signal against
noise, record, decode, log bookmarks).

This folder is both a Claude Code plugin (`.claude-plugin/plugin.json`, `.mcp.json`) and a portable Agent Plugin
for Hermes Agent (`plugin.json` and `skills/`). The skill is `skills/subfloor-radio/SKILL.md`; the full tool
reference is `skills/subfloor-radio/references/tools.md`.

First, in SubFloor: click the **MCP** button in the top bar (or Radio › MCP Server…), tick **Enable the MCP
server**, and copy the token. The window's **Setup** tab shows these steps with your port and token filled in.
SubFloor answers only this Mac (127.0.0.1) and only requests carrying the token.

## Claude Code

1. Paste these into Claude Code one at a time:
   ```
   /plugin marketplace add RidgebackZulu/SubFloor
   /plugin install subfloor@subfloor
   ```
2. Put the token in `~/.zshenv` (in a text editor, not at a prompt), then start Claude Code from a new Terminal:
   ```sh
   export SUBFLOOR_MCP_TOKEN=<token>
   export SUBFLOOR_MCP_URL=http://127.0.0.1:7824/mcp   # only if you changed the port
   ```

## Hermes Agent

Install this folder (not the whole repository, which is the app's source), then connect SubFloor's MCP server
while SubFloor is running with MCP switched on:

```sh
hermes plugins install RidgebackZulu/SubFloor/plugins/subfloor --enable
hermes mcp add subfloor --url http://127.0.0.1:7824/mcp --auth header
```

The plugin brings the `subfloor-radio` skill. `hermes mcp add` asks for the Bearer token (paste the one from
SubFloor's **Copy Token**), keeps it in Hermes' secrets and enables SubFloor's tools. Use your port if you changed
it. Then `/reload-mcp` in Hermes, or start a new session.

If Hermes stops with "maximum number of tool-calling iterations", that is Hermes' own per-turn cap, not SubFloor:
`hermes config set agent.max_turns unlimited` lifts it. A band scan or a pirate hunt takes many calls.

## Other agents

Codex, Gemini CLI, Cursor, VS Code, Claude Desktop and others connect without the plugin: SubFloor's MCP window
has a snippet for each. They get the tools but not the skill; pointing them at
`skills/subfloor-radio/SKILL.md` helps.
