import Foundation
import Network
import Observation

/// What the MCP button shows.
enum MCPState: Equatable, Sendable {
    /// Turned off, or not started yet.
    case off
    /// Turned on but not listening, and why.
    case failed(String)
    /// Listening, with no agent active within `MCPSessions.connectedSeconds`.
    case listening
    /// Listening, and `client` ("name version") was the agent most recently active.
    case connected(client: String)
}

/// The MCP server: plain HTTP on 127.0.0.1 in front of `MCPRPC`, with its settings, its bearer token (in the
/// Keychain) and its state. Sockets live on a private queue; every request is answered on the main actor,
/// one at a time per connection and in order.
@MainActor @Observable
final class MCPServer {
    private(set) var state: MCPState = .off
    private(set) var settings: MCPSettings
    /// Created and saved on first use if the store has none.
    private(set) var token: String
    /// Goes up by one for every request answered, so the button can flash.
    private(set) var pulse = 0
    /// The port actually listened on (an ephemeral one for port 0), or nil when not listening.
    private(set) var boundPort: UInt16?
    let log: MCPLog

    /// The client of every session active within `MCPSessions.connectedSeconds`, the most recent first.
    var connectedClients: [String] {
        _ = pulse   // observed through `pulse`: sessions change only when a request is answered
        return rpc.sessions.connectedClients(now: Date())
    }

    @ObservationIgnored private let provider: MCPToolProvider
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let tokenStore: APIKeyStore
    @ObservationIgnored private lazy var rpc: MCPRPC = makeRPC()
    @ObservationIgnored private let queue = DispatchQueue(label: "app.subfloor.SubFloor.mcp")
    @ObservationIgnored private var listener: NWListener?
    /// The port the current listener was asked for (`settings.port` when it started).
    @ObservationIgnored private var listenerPort: Int?
    @ObservationIgnored private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Bumped whenever the listener closes, so callbacks from an old one are ignored.
    @ObservationIgnored private var generation = 0
    /// `start` callers waiting for the listener to be ready or to fail.
    @ObservationIgnored private var startWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(provider: MCPToolProvider, defaults: UserDefaults = .standard,
         tokenStore: APIKeyStore = KeychainAPIKeyStore(service: "app.subfloor.SubFloor.mcp", account: "token"),
         log: MCPLog = MCPLog(fileURL: MCPLog.defaultFileURL)) {
        self.provider = provider
        self.defaults = defaults
        self.tokenStore = tokenStore
        self.log = log
        settings = MCPSettings.load(defaults)
        if let saved = tokenStore.load(), !saved.isEmpty {
            token = saved
        } else {
            token = MCPAuth.generateToken()
            saveToken()
        }
    }

    /// Saves `s`, then starts the server, restarts it on a port change, or stops it. A server that failed
    /// tries again.
    func apply(_ s: MCPSettings) async {
        settings = s
        s.save(defaults)
        guard s.enabled else { return stop() }
        guard s.port == 0 || MCPSettings.allowedPorts.contains(s.port) else {
            stop()
            state = .failed("Port \(s.port) is not allowed (1024–65535)")
            return
        }
        if listener != nil, listenerPort == s.port {
            if boundPort == nil { await withCheckedContinuation { startWaiters.append($0) } }
            return
        }
        await start(port: s.port)
    }

    /// A new token, saved; the server restarts so connections made with the old one close.
    func newToken() {
        token = MCPAuth.generateToken()
        saveToken()
        log.add(.server, client: nil, "New token: agents need the new one")
        guard listener != nil, let port = listenerPort else { return }
        closeListener()
        state = .listening
        let restart = generation
        Task {
            guard restart == generation else { return }   // stopped or applied meanwhile
            await start(port: port)
        }
    }

    /// Closes the listener and every connection. The settings are left as they are.
    func stop() {
        let wasRunning = listener != nil
        closeListener()
        state = .off
        if wasRunning { log.add(.server, client: nil, "Stopped") }
    }

    // MARK: Listener

    private func start(port: Int) async {
        closeListener()
        let current = generation
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            return fail(port: port, error: error)
        }
        listener.stateUpdateHandler = { [weak self] newState in
            let server = self
            Self.onMain { server?.listenerChanged(newState, port: port, generation: current) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            let server = self
            Self.onMain {
                guard let server else { return connection.cancel() }
                server.accept(connection, generation: current)
            }
        }
        self.listener = listener
        listenerPort = port
        listener.start(queue: queue)
        await withCheckedContinuation { startWaiters.append($0) }
    }

    private func listenerChanged(_ newState: NWListener.State, port: Int, generation current: Int) {
        guard current == generation, let listener else { return }
        switch newState {
        case .ready:
            boundPort = listener.port?.rawValue
            log.add(.server, client: nil, "Listening on http://127.0.0.1:\(boundPort ?? 0)/mcp")
            refreshState()
            startRefreshing()
            resumeStartWaiters()
        case .failed(let error), .waiting(let error):
            fail(port: port, error: error)
        default:
            break
        }
    }

    private func fail(port: Int, error: Error) {
        closeListener()
        if case .posix(.EADDRINUSE) = error as? NWError {
            state = .failed("Port \(port) is in use")
        } else {
            state = .failed("Could not start on port \(port)")
        }
        log.add(.error, client: nil, "Could not start on port \(port): \(error)")
    }

    /// Cancels the listener and its connections and ends every session; `state` is left to the caller.
    private func closeListener() {
        generation += 1
        listener?.cancel()
        listener = nil
        listenerPort = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
        boundPort = nil
        rpc.sessions.endAll()
        resumeStartWaiters()
    }

    private func resumeStartWaiters() {
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// `.listening` or `.connected` from the sessions, while listening.
    private func refreshState() {
        guard boundPort != nil else { return }
        let next = rpc.sessions.connectedClient(now: Date()).map { MCPState.connected(client: $0) } ?? .listening
        if next != state { state = next }
    }

    /// Every 5 s, so `.connected` lapses to `.listening` without a request.
    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                refreshState()
            }
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection, generation current: Int) {
        guard current == generation else { return connection.cancel() }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        Task { await serve(connection, generation: current) }
    }

    /// Reads requests off `connection` and answers each before reading the next, until either side closes.
    private func serve(_ connection: NWConnection, generation current: Int) async {
        defer {
            connection.cancel()
            connections[ObjectIdentifier(connection)] = nil
        }
        var buffer = Data()
        while current == generation {
            switch HTTPParser.parse(buffer) {
            case .incomplete:
                guard let chunk = await Self.receive(connection) else { return }
                buffer.append(chunk)
            case .failure(let status, let message):
                await Self.send(HTTPResponse.error(status, message, close: true).serialized(), on: connection)
                return
            case .request(let request, let consumed):
                buffer = Data(buffer.dropFirst(consumed))
                var response = await rpc.handle(request)
                guard current == generation else { return }
                if request.headers["connection"]?.lowercased().contains("close") == true { response.close = true }
                refreshState()
                await Self.send(response.serialized(), on: connection)
                if response.close { return }
            }
        }
    }

    /// The next bytes from `connection`, or nil once it is closed or failed.
    private nonisolated static func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                done.resume(returning: data.flatMap { $0.isEmpty ? nil : $0 })
            }
        }
    }

    private nonisolated static func send(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in done.resume() })
        }
    }

    /// Runs `body` on the main actor, in the order called.
    private nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }

    // MARK: Setup

    private func makeRPC() -> MCPRPC {
        let rpc = MCPRPC(provider: provider, log: log, token: { [weak self] in self?.token ?? "" })
        rpc.onActivity = { [weak self] in self?.pulse += 1 }
        return rpc
    }

    private func saveToken() {
        do {
            try tokenStore.save(token)
        } catch {
            log.add(.error, client: nil, "Could not save the token in the Keychain: \(error)")
        }
    }
}
