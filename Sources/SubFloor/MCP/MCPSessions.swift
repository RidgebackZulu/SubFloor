import Foundation

/// The MCP sessions the server has seen and when each was last active. "Connected" means some session was
/// active within `connectedSeconds`.
struct MCPSessions {
    static let connectedSeconds: TimeInterval = 300

    private struct Session {
        var client: String
        var lastSeen: Date
    }

    /// Live sessions by id. A client that sends no session id is kept under "".
    private var live: [String: Session] = [:]
    /// Every id handed out, with its client. Clients keep their id across a restart of the server, so a
    /// resumed session gets its name back.
    private(set) var knownClients: [String: String] = [:]

    /// A new session for `client` (as "name version"); returns its id.
    mutating func begin(client: String, now: Date) -> String {
        let id = UUID().uuidString.lowercased()
        live[id] = Session(client: client, lastSeen: now)
        knownClients[id] = client
        return id
    }

    /// Marks session `id` (nil: a client without one) active. An id not live now becomes a live session,
    /// named from `knownClients` or "MCP client"; `isNew` says so.
    @discardableResult
    mutating func touch(_ id: String?, now: Date) -> (client: String, isNew: Bool) {
        let key = id ?? ""
        if var s = live[key] {
            s.lastSeen = now
            live[key] = s
            return (s.client, false)
        }
        let client = knownClients[key] ?? "MCP client"
        live[key] = Session(client: client, lastSeen: now)
        return (client, true)
    }

    /// Ends session `id`; returns its client, or nil if it was not live.
    mutating func end(_ id: String) -> String? {
        live.removeValue(forKey: id)?.client
    }

    /// Ends every live session (the server stopped), remembering who held each id.
    mutating func endAll() {
        live.removeAll()
    }

    /// The client of live session `id` (nil: the client without one).
    func clientName(_ id: String?) -> String? {
        live[id ?? ""]?.client
    }

    /// The client of every session active within `connectedSeconds` of `now`, the most recent first.
    func connectedClients(now: Date) -> [String] {
        live.values
            .filter { now.timeIntervalSince($0.lastSeen) < Self.connectedSeconds }
            .sorted { $0.lastSeen > $1.lastSeen }
            .map(\.client)
    }

    /// The client most recently active within `connectedSeconds` of `now`, or nil.
    func connectedClient(now: Date) -> String? {
        live.values
            .filter { now.timeIntervalSince($0.lastSeen) < Self.connectedSeconds }
            .max { $0.lastSeen < $1.lastSeen }?
            .client
    }
}
