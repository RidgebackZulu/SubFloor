import SwiftUI

/// Top-bar pill: grey when the MCP server is off, blue while it listens, green with a soft glow while an agent
/// is connected. Each request answered pulses the glow once. Click for the MCP window.
struct MCPButton: View {
    @Environment(MCPServer.self) private var server
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button { openWindow(id: "mcp") } label: { MCPPill(state: server.state, pulse: server.pulse) }
            .buttonStyle(.plain)
            .help(Self.tooltip(for: server.state, port: server.settings.port))
            .accessibilityLabel("MCP server")
            .accessibilityValue(MCPWindow.statusLine(for: server.state, url: server.settings.url))
    }

    static func tooltip(for state: MCPState, port: Int) -> String {
        switch state {
        case .off: "MCP server off: click to let AI agents use SubFloor"
        case .failed(let reason) where MCPWindow.portInUse(reason): "MCP server could not start: port \(port) is in use"
        case .failed(let reason): "MCP server could not start: \(MCPWindow.lowercasingFirst(reason))"
        case .listening: "MCP server listening, no agent connected"
        case .connected(let client): "\(client) connected"
        }
    }
}

/// What `MCPButton` draws, 74×24. The glow is steady while connected; a change of `pulse` brightens it and lets
/// it settle over 0.6 s, at most 30 frames a second, and a pulse already rising absorbs the next. Nothing
/// animates otherwise.
struct MCPPill: View {
    let state: MCPState
    let pulse: Int
    @Environment(\.colorScheme) private var scheme
    @State private var pulseStart: Date?

    static let off = Color(red: 150 / 255, green: 157 / 255, blue: 168 / 255)
    static let connected = Color(red: 30 / 255, green: 154 / 255, blue: 84 / 255)
    static let pulseSeconds = 0.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: pulseStart == nil)) { context in
            pill(glow: glow(at: context.date))
        }
        .onChange(of: pulse) { startPulse() }
        .onChange(of: state) { if !isConnected { pulseStart = nil } }
    }

    private var isConnected: Bool {
        if case .connected = state { true } else { false }
    }

    private var color: Color {
        switch state {
        case .off, .failed: Self.off
        case .listening: Theme.accent
        case .connected: Self.connected
        }
    }

    /// Lighter on dark, darker on light, so the word reads on either.
    private var textColor: Color {
        switch state {
        case .off, .failed: scheme == .dark ? Color(white: 0.78) : Color(white: 0.36)
        case .listening: scheme == .dark ? Theme.accent : Color(red: 0.05, green: 0.42, blue: 0.62)
        case .connected:
            scheme == .dark ? Color(red: 0.42, green: 0.86, blue: 0.58) : Color(red: 0.06, green: 0.40, blue: 0.21)
        }
    }

    /// 0 steady, rising to 1 halfway through a pulse and back.
    private func glow(at date: Date) -> Double {
        guard let pulseStart else { return 0 }
        let t = date.timeIntervalSince(pulseStart) / Self.pulseSeconds
        guard t > 0, t < 1 else { return 0 }
        return sin(t * .pi)
    }

    private func startPulse() {
        guard isConnected else { return }
        let now = Date()
        if let pulseStart, now.timeIntervalSince(pulseStart) < Self.pulseSeconds / 2 { return }   // still rising
        pulseStart = now
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.pulseSeconds))
            if pulseStart == now { pulseStart = nil }
        }
    }

    private func pill(glow: Double) -> some View {
        let connected = isConnected
        let failed = if case .failed = state { true } else { false }
        return HStack(spacing: 6) {
            if failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.orange)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .shadow(color: color.opacity(connected ? 0.9 : 0), radius: connected ? 3 + 2 * glow : 0)
            }
            Text("MCP").font(.system(size: 12, weight: .bold)).foregroundStyle(textColor)
        }
        .frame(width: 74, height: 24)
        .background(Capsule().fill(color.opacity(state == .off || failed ? 0.08 : 0.14)))
        .overlay(Capsule().strokeBorder(color.opacity(connected ? 0.9 : 0.7), lineWidth: 1))
        .shadow(color: color.opacity(connected ? 0.55 + 0.45 * glow : 0), radius: connected ? 6 + 6 * glow : 0)
        .contentShape(Capsule())
    }
}
