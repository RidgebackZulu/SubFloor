import Foundation
import Observation

/// One line of the MCP event log.
struct MCPEvent: Codable, Identifiable, Equatable {
    var id: UUID
    var time: Date
    var kind: Kind
    /// The agent's "name version", when the event is about one.
    var client: String?
    var summary: String
    /// Arguments or a result, shortened.
    var detail: String?

    enum Kind: String, Codable, CaseIterable {
        case server, connect, disconnect, call, result, error, auth

        var displayName: String {
            switch self {
            case .server: "Server"
            case .connect: "Connected"
            case .disconnect: "Disconnected"
            case .call: "Tool call"
            case .result: "Result"
            case .error: "Error"
            case .auth: "Refused"
            }
        }
    }
}

/// Everything the MCP server does: the newest events in memory for the setup window, and every event as a
/// JSON line in a small file that drops its oldest lines.
@MainActor @Observable
final class MCPLog {
    private(set) var events: [MCPEvent] = []
    @ObservationIgnored private let maxEvents: Int
    @ObservationIgnored private let file: LogFile?
    @ObservationIgnored private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// `~/Library/Logs/SubFloor/mcp.log`.
    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SubFloor/mcp.log")
    }

    /// `fileURL` nil keeps the log in memory only.
    init(fileURL: URL?, maxEvents: Int = 1_000, maxFileBytes: Int = 1_048_576) {
        self.maxEvents = maxEvents
        file = fileURL.map { LogFile(url: $0, maxBytes: maxFileBytes) }
    }

    func add(_ kind: MCPEvent.Kind, client: String?, _ summary: String, detail: String? = nil) {
        let event = MCPEvent(id: UUID(), time: Date(), kind: kind, client: client, summary: summary, detail: detail)
        events.append(event)
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
        if let file, var line = try? encoder.encode(event) {
            line.append(0x0A)
            file.append(line)
        }
    }

    /// Empties the window's list. The file keeps every line.
    func clearView() {
        events.removeAll()
    }

    /// Returns once every line added so far is in the file.
    func flushed() async {
        await file?.flushed()
    }
}

/// The log file, written on a queue of its own so the main thread never waits for the disk.
private final class LogFile: Sendable {
    let url: URL
    let maxBytes: Int
    private let queue = DispatchQueue(label: "app.subfloor.SubFloor.mcp-log")

    init(url: URL, maxBytes: Int) {
        self.url = url
        self.maxBytes = maxBytes
    }

    func append(_ line: Data) {
        queue.async { [self] in write(line) }
    }

    func flushed() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { done.resume() }
        }
    }

    private func write(_ line: Data) {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int
        guard let size else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? trimmed(line).write(to: url, options: .atomic)
            return
        }
        if size + line.count <= maxBytes, let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if (try? handle.seekToEnd()) != nil, (try? handle.write(contentsOf: line)) != nil { return }
        }
        let old = (try? Data(contentsOf: url)) ?? Data()
        try? trimmed(old + line).write(to: url, options: .atomic)
    }

    /// The newest whole lines of `data`, in at most three quarters of `maxBytes`, so the file is not
    /// rewritten for every line once it is full.
    private func trimmed(_ data: Data) -> Data {
        guard data.count > maxBytes else { return data }
        let budget = maxBytes * 3 / 4
        var start = data.endIndex - budget
        // Start after a line break, so the first line kept is whole.
        guard let newline = data[(start - 1)...].firstIndex(of: 0x0A) else { return Data() }
        start = newline + 1
        return Data(data[start...])
    }
}
