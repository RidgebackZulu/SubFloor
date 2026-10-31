import Foundation

/// Whether the MCP server runs and on which port, saved as JSON under `UserDefaults` key `mcp`. Off by default.
struct MCPSettings: Codable, Equatable, Sendable {
    static let defaultsKey = "mcp"
    static let defaultPort = 7824
    /// The ports `MCPServer.apply` accepts (0, an ephemeral port, is for tests only).
    static let allowedPorts = 1024...65535

    var enabled = false
    /// Stored as given; `MCPServer.apply` refuses one outside `allowedPorts`.
    var port = MCPSettings.defaultPort

    init(enabled: Bool = false, port: Int = MCPSettings.defaultPort) {
        self.enabled = enabled
        self.port = port
    }

    /// A missing field takes its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort
    }

    /// The saved settings, or the defaults when there are none or they cannot be read.
    static func load(_ d: UserDefaults) -> MCPSettings {
        d.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(MCPSettings.self, from: $0) } ?? MCPSettings()
    }

    func save(_ d: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.defaultsKey) }
    }

    /// The endpoint an agent is given: `http://127.0.0.1:<port>/mcp`.
    var url: String { "http://127.0.0.1:\(port)/mcp" }
}
