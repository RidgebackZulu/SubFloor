import AppKit
import SwiftUI

/// Radio › MCP Server…, or the MCP button: the server's switch, port, token and status, how to connect each
/// agent, and the event log.
struct MCPWindow: View {
    var body: some View {
        TabView {
            MCPSetupTab().tabItem { Text("Setup") }
            MCPEventLogTab().tabItem { Text("Event log") }
        }
        .padding(12)
        .frame(minWidth: 820, minHeight: 600)
    }

    static func statusLine(for state: MCPState, url: String) -> String {
        switch state {
        case .off: "● Off"
        case .failed(let reason) where portInUse(reason): "● Could not start: port in use"
        case .failed(let reason) where reason.hasPrefix("Could not start"): "● \(reason)"
        case .failed(let reason): "● Could not start: \(lowercasingFirst(reason))"
        case .listening: "● Listening on \(url) — no agent connected"
        case .connected(let client): "● Connected — \(client)"
        }
    }

    /// `MCPServer` says "Port 7824 is in use" when the port is taken.
    static func portInUse(_ reason: String) -> Bool { reason.hasSuffix("is in use") }

    static func lowercasingFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

    static func color(for state: MCPState) -> Color {
        switch state {
        case .off: MCPPill.off
        case .failed: .orange
        case .listening: Theme.accent
        case .connected: MCPPill.connected
        }
    }

    /// `text` with the token masked unless the Token field is showing it: what the window displays of a
    /// snippet or a command's output. Copy and Add use the real text.
    static func displayed(_ text: String, token: String, showToken: Bool) -> String {
        showToken || token.isEmpty ? text : text.replacingOccurrences(of: token, with: AgentSnippets.mask)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: Setup

struct MCPSetupTab: View {
    @Environment(MCPServer.self) private var server
    @State private var portText = ""
    @State private var showToken = false
    @State private var confirmNewToken = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            serverSection
            Divider()
            tokenSection
            Divider()
            MCPConnectAgent(showToken: showToken)
            Divider()
            Text(LocalizedStringKey(Self.skillLine))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .onAppear {
            portText = String(server.settings.port)
            server.loadToken()
        }
        .alert("Make a new token?", isPresented: $confirmNewToken) {
            Button("New Token", role: .destructive) { server.newToken() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Agents using the old token will be disconnected until you paste the new one.")
        }
    }

    /// Markdown, for the code spans.
    static let skillLine = "The SubFloor skill teaches an agent to drive the radio well (squelch, hunting, logging). "
        + "Claude Code: `/plugin marketplace add RidgebackZulu/SubFloor`, then `/plugin install subfloor@subfloor`. "
        + "Hermes: `hermes plugins install RidgebackZulu/SubFloor/plugins/subfloor --enable`."

    private var port: Int? {
        Int(portText.trimmingCharacters(in: .whitespaces)).flatMap { MCPSettings.allowedPorts.contains($0) ? $0 : nil }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Enable the MCP server", isOn: Binding(
                get: { server.settings.enabled },
                set: { on in
                    let s = MCPSettings(enabled: on, port: server.settings.port)
                    Task { await server.apply(s) }
                }))
            .toggleStyle(.switch)
            .font(.headline)
            HStack(spacing: 8) {
                Text("Port")
                TextField("Port", text: $portText)
                    .labelsHidden()
                    .frame(width: 80)
                    .monospacedDigit()
                    .onSubmit(applyPort)
                Button("Apply", action: applyPort)
                    .disabled(port == nil || port == server.settings.port)
                if port == nil {
                    Text("Use a port from 1024 to 65535").font(.callout).foregroundStyle(.red)
                }
            }
            let status = MCPWindow.statusLine(for: server.state, url: server.settings.url)
            HStack(spacing: 6) {
                Text("Status").foregroundStyle(.secondary)
                (Text("●").foregroundStyle(MCPWindow.color(for: server.state)) + Text(status.dropFirst()))
                    .textSelection(.enabled)
            }
        }
    }

    private func applyPort() {
        guard let port, port != server.settings.port else { return }
        let s = MCPSettings(enabled: server.settings.enabled, port: port)
        Task { await server.apply(s) }
    }

    private var tokenSection: some View {
        HStack(spacing: 8) {
            Text("Token").foregroundStyle(.secondary)
            Text(showToken ? server.token : String(repeating: "•", count: 24))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .frame(minWidth: 340, alignment: .leading)
            Button(showToken ? "Hide" : "Show") { showToken.toggle() }
            Button("Copy") { MCPWindow.copy(server.token) }
            Button("New Token…") { confirmNewToken = true }
            Spacer(minLength: 0)
        }
    }
}

/// The agent list on the left; the chosen agent's snippet on the right, with Copy and, where its tool is
/// installed, Add.
private struct MCPConnectAgent: View {
    /// The Token field's Show: until then the snippets display the token masked.
    let showToken: Bool
    @Environment(MCPServer.self) private var server
    @State private var selection: AgentSnippet.ID? = "claude-code"
    /// Executable → found on this Mac.
    @State private var found: [String: Bool] = [:]
    @State private var running = false
    @State private var output: [AgentSnippet.ID: (ok: Bool, text: String)] = [:]

    var body: some View {
        let snippets = AgentSnippets.all(url: server.settings.url, token: server.token)
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect an agent").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                List(snippets, selection: $selection) { Text($0.name).tag($0.id) }
                    .listStyle(.bordered)
                    .frame(width: 190)
                if let snippet = snippets.first(where: { $0.id == selection }) {
                    detail(snippet)
                } else {
                    Text("Choose an agent").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task {
            let executables = Set(snippets.compactMap { $0.install?.executable })
            for exe in executables {
                found[exe] = await AgentInstaller.find(exe) != nil
            }
        }
    }

    private func shown(_ text: String) -> String {
        MCPWindow.displayed(text, token: server.token, showToken: showToken)
    }

    private func box(_ text: String) -> some View {
        ScrollView {
            Text(shown(text))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
    }

    private func detail(_ snippet: AgentSnippet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snippet.whereItGoes)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            box(snippet.text)
                .frame(maxHeight: .infinity, alignment: .top)
            if let extra = snippet.extra {
                box(extra.text)
                    .frame(height: 64)
            }
            HStack(spacing: 8) {
                Button("Copy") { MCPWindow.copy(snippet.text) }
                if let extra = snippet.extra {
                    Button(extra.copyLabel) { MCPWindow.copy(extra.text) }
                }
                if snippet.asksForToken {
                    Button("Copy Token") { MCPWindow.copy(server.token) }
                }
                if let install = snippet.install {
                    let available = found[install.executable] == true
                    Button("Add to \(snippet.name)") { add(snippet.id, install) }
                        .disabled(!available || running)
                        .help(available ? "Runs \(install.executable) mcp add on this Mac"
                              : found[install.executable] == nil ? "Looking for \(install.executable)…"
                              : "\(install.executable) isn't installed on this Mac")
                    if running { ProgressView().controlSize(.small) }
                }
            }
            if let result = output[snippet.id] {
                ScrollView {
                    Text(result.text.isEmpty ? (result.ok ? "Done." : "Failed.") : shown(result.text))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(result.ok ? Color.primary : Color.orange)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: 70)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func add(_ id: AgentSnippet.ID, _ install: AgentInstall) {
        running = true
        Task {
            let result = await AgentInstaller.run(install)
            output[id] = (result.ok, result.output)
            running = false
        }
    }
}

// MARK: Event log

struct MCPEventLogTab: View {
    @Environment(MCPServer.self) private var server
    @State private var filter = ""
    @State private var selection: MCPEvent.ID?

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Newest first, matching every word of the filter somewhere in the event.
    private var events: [MCPEvent] {
        let words = filter.lowercased().split(separator: " ")
        return server.log.events.reversed().filter { e in
            guard !words.isEmpty else { return true }
            let text = [e.kind.displayName, e.client ?? "", e.summary, e.detail ?? ""].joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        let events = events
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Spacer()
                Button("Clear view") {
                    selection = nil
                    server.log.clearView()
                }
                Button("Open log folder") { openLogFolder() }
            }
            Table(events, selection: $selection) {
                TableColumn("Time") { Text(Self.time.string(from: $0.time)).monospacedDigit() }
                    .width(min: 64, ideal: 70, max: 90)
                TableColumn("Event") { e in Text(e.kind.displayName).foregroundStyle(Self.color(e.kind)) }
                    .width(min: 70, ideal: 90, max: 120)
                TableColumn("Client") { Text($0.client ?? "") }
                    .width(min: 80, ideal: 140, max: 220)
                TableColumn("Summary") { Text($0.summary).lineLimit(1) }
            }
            ScrollView {
                Text(detail(events.first { $0.id == selection }))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(selection == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }
        .padding(16)
    }

    private func detail(_ e: MCPEvent?) -> String {
        guard let e else { return "Select an event to see its arguments or result." }
        let head = [Self.time.string(from: e.time), e.kind.displayName, e.client].compactMap { $0 }.joined(separator: "  ")
        return [head, e.summary, e.detail].compactMap { $0 }.joined(separator: "\n\n")
    }

    private static func color(_ kind: MCPEvent.Kind) -> Color {
        switch kind {
        case .server: .secondary
        case .connect, .result: MCPPill.connected
        case .disconnect: .secondary
        case .call: Theme.accent
        case .error: .orange
        case .auth: .red
        }
    }

    private func openLogFolder() {
        let folder = MCPLog.defaultFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
