import DSPCore
import Foundation
import Recording
import SubFloorCore
import Transcription

/// One SubFloor tool: what `tools/list` shows, and what a call runs. `run` returns the result's fields
/// (`"ok": true` is added) or throws a `ToolError` whose message is the tool error.
struct SubFloorTool {
    var descriptor: MCPToolDescriptor
    /// The call runs inside `withRadio`. Every tool that changes the radio does, except one that waits on the
    /// radio for a long time (`listen`), which takes the lock itself only for as long as it must.
    var locksRadio: Bool
    var run: @MainActor (SubFloorTools, ToolArguments, _ client: String) async throws -> [String: JSONValue]

    init(_ name: String, title: String, readOnly: Bool, locksRadio: Bool? = nil, description: String,
         properties: [String: JSONValue] = [:], required: [String] = [],
         run: @escaping @MainActor (SubFloorTools, ToolArguments, _ client: String) async throws -> [String: JSONValue]) {
        descriptor = MCPToolDescriptor(name: name, title: title, description: description,
                                       inputSchema: .inputSchema(properties: properties, required: required),
                                       readOnly: readOnly)
        self.locksRadio = locksRadio ?? !readOnly
        self.run = run
    }
}

/// What a `listen` watches for: the tuning, the mode and whether the radio runs.
struct RadioState: Equatable {
    var vfoHz: Double
    var mode: DemodMode
    var running: Bool
}

/// The last change an agent's call made to the radio's state, so a `listen` it interrupted can say who did it.
struct RadioChange {
    var client: String
    var at: Date
    /// The state the call left.
    var state: RadioState
}

/// A failed precondition or a bad argument: `message` says what to do, and is the tool error's text.
struct ToolError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

/// SubFloor's tools over the app's model. Read-only tools run at once; the others run one at a time, in the
/// order they were called (`withRadio`), except `listen`, which holds the radio only while it starts.
@MainActor
final class SubFloorTools: MCPToolProvider {
    let model: AppModel
    /// The agents connected to the server, for `get_status` (set by the app from `MCPServer.connectedClients`).
    var connectedClients: () -> [String] = { [] }
    let tools: [MCPToolDescriptor]
    private let registry: [String: SubFloorTool]
    private var radioBusy = false
    private var radioWaiters: [CheckedContinuation<Void, Never>] = []
    /// The recordings agents started that may still run, each with the task that stops it (`start_recording`).
    var agentRecordings: [StreamKind: AgentRecording] = [:]
    /// The last change an agent's call made to the tuning, mode or running state.
    private(set) var lastRadioChange: RadioChange?
    /// How often an agent's recording checks the free disk space (tests shorten it).
    var recordingDiskCheckInterval: Duration = .seconds(2)
    /// The MCP event log, for what the tools do on their own (set by the app from `MCPServer.log`).
    var log: MCPLog?
    /// The clock `get_cursor` ages the mouse by (tests move it).
    var now: () -> Date = { Date() }
    /// Whether the IQ ring holds `seconds` of IQ since the last retune: what `identify_signals` waits for after
    /// each step (tests answer at once).
    var ringReady: @MainActor (_ seconds: Double) -> Bool = { _ in true }
    /// How long a scan waits for the ring to fill before it reads what there is (the answer says how much).
    var ringWaitLimit: Duration = .seconds(20)
    /// The spectrum a scan picks its signals from (tests supply their own).
    var scanSpectrum: @MainActor () -> SpectrumSnapshot? = { nil }
    /// The longer reads `get_cursor` started that are still running, by frequency (`quickIdentity`).
    var cursorReads: [Int: CursorRead] = [:]

    /// `extraTools`: a test's own tools, offered beside SubFloor's.
    init(model: AppModel, extraTools: [SubFloorTool] = []) {
        self.model = model
        let all = Self.radioTools + Self.signalTools + Self.bookmarkTools + Self.recordingTools + Self.decodeTools + extraTools
        tools = all.map(\.descriptor)
        registry = Dictionary(all.map { ($0.descriptor.name, $0) }, uniquingKeysWith: { first, _ in first })
        ringReady = { [unowned model] seconds in
            let ring = model.engine.iqRecorder
            // A ring that cannot hold the asked-for span is as full as it gets when it is nearly full.
            return ring.status.preRollFill * ring.effectivePreRollSeconds >= min(seconds, 0.98 * ring.effectivePreRollSeconds)
        }
        scanSpectrum = { [unowned model] in model.spectrumSnapshot() }
    }

    func call(_ name: String, arguments: [String: JSONValue], client: String) async -> MCPToolResult {
        guard let tool = registry[name] else { return .failure("Unknown tool \(name)") }
        let args = ToolArguments(arguments)
        let run = { () async -> MCPToolResult in
            // Only a tool that changes the radio, run under the lock, can be the change: whatever else changed
            // while a read or a listen was waiting was someone else's doing.
            let before = tool.locksRadio ? self.radioState : nil
            defer {
                let after = self.radioState
                if let before, after != before { self.lastRadioChange = RadioChange(client: client, at: Date(), state: after) }
            }
            do {
                var fields = try await tool.run(self, args, client)
                fields["ok"] = .bool(true)
                return .ok(.object(fields))
            } catch let e as ToolError {
                return .failure(e.message)
            } catch {
                return .failure("\(name) failed: \(error.localizedDescription)")
            }
        }
        return tool.locksRadio ? await withRadio(run) : await run()
    }

    var radioState: RadioState { RadioState(vfoHz: model.vfoHz, mode: model.mode, running: model.isRunning) }

    /// Notes that `client`'s call just changed the radio to the state it is in, for a call that changes it in
    /// steps (`identify_signals`): a `listen` it interrupts then says who did it.
    func noteRadioChange(by client: String) {
        lastRadioChange = RadioChange(client: client, at: Date(), state: radioState)
    }

    /// Who made the radio `now` since `since`: the agent whose call left it so, or the owner.
    func changedBy(_ now: RadioState, since: Date) -> String {
        if let c = lastRadioChange, c.at >= since, c.state == now { return c.client }
        return "the owner"
    }

    // MARK: Radio lock

    /// Runs `body` once every earlier caller has finished, in call order: the radio changes one agent action
    /// at a time. Read-only tools never take it.
    func withRadio<T>(_ body: () async throws -> T) async rethrows -> T {
        if radioBusy {
            await withCheckedContinuation { radioWaiters.append($0) }   // handed over by the finishing caller
        } else {
            radioBusy = true
        }
        defer {
            if radioWaiters.isEmpty { radioBusy = false } else { radioWaiters.removeFirst().resume() }
        }
        return try await body()
    }

    /// Callers waiting for the radio (tests).
    var radioWaiting: Int { radioWaiters.count }

    // MARK: Shared checks

    /// Fails unless the radio runs.
    func requireRunning() throws {
        guard model.isRunning else { throw ToolError("The radio is stopped: call start_radio first.") }
    }

    /// Runs `work` off the main actor: file reads and blocking queries never hold up the app.
    func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }
}

// MARK: - Arguments

/// A call's arguments, read with defaults and clamps. A value of the wrong type throws a `ToolError` naming
/// the argument; a missing one is nil or the default.
struct ToolArguments {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) { self.values = values }

    func has(_ key: String) -> Bool { values[key].map { $0 != .null } ?? false }

    /// The value of `read(key)`, or a `ToolError` saying `key` is needed.
    func required<T>(_ key: String, _ read: (String) throws -> T?) throws -> T {
        guard let v = try read(key) else { throw ToolError("\(key) is required.") }
        return v
    }

    /// Display Hz from a number, or from a string such as "7.074 MHz", "7074k" or "6925" (`FrequencyParser`:
    /// a bare number under 3000 is MHz, under 3 000 000 kHz). The range is not checked.
    func frequency(_ key: String) throws -> Double? {
        switch values[key] {
        case nil, .null?: return nil
        case .number(let n)?:
            guard n.isFinite else { throw ToolError("\(key) must be a finite number of Hz.") }
            return n
        case .string(let s)?:
            guard let hz = FrequencyParser.parse(s) else {
                throw ToolError("\(key) \"\(s)\" is not a frequency: give Hz as a number, or a string like \"7.074 MHz\".")
            }
            return hz
        default:
            throw ToolError("\(key) must be a frequency: Hz as a number, or a string like \"7.074 MHz\".")
        }
    }

    func double(_ key: String, in range: ClosedRange<Double>? = nil) throws -> Double? {
        switch values[key] {
        case nil, .null?: return nil
        case .number(let n)? where n.isFinite: return range.map { min(max(n, $0.lowerBound), $0.upperBound) } ?? n
        default: throw ToolError("\(key) must be a number.")
        }
    }

    func double(_ key: String, default d: Double, in range: ClosedRange<Double>? = nil) throws -> Double {
        try double(key, in: range) ?? d
    }

    /// Rounded to the nearest whole number, then clamped.
    func int(_ key: String, in range: ClosedRange<Int>? = nil) throws -> Int? {
        guard let n = try double(key) else { return nil }
        guard abs(n) < 1e15 else { throw ToolError("\(key) must be a whole number.") }
        let i = Int(n.rounded())
        return range.map { min(max(i, $0.lowerBound), $0.upperBound) } ?? i
    }

    func int(_ key: String, default d: Int, in range: ClosedRange<Int>? = nil) throws -> Int {
        try int(key, in: range) ?? d
    }

    func bool(_ key: String) throws -> Bool? {
        switch values[key] {
        case nil, .null?: return nil
        case .bool(let b)?: return b
        default: throw ToolError("\(key) must be true or false.")
        }
    }

    func bool(_ key: String, default d: Bool) throws -> Bool { try bool(key) ?? d }

    /// Trimmed; an empty string is nil.
    func string(_ key: String) throws -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case .string(let s)?:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        default: throw ToolError("\(key) must be a string.")
        }
    }

    func string(_ key: String, default d: String) throws -> String { try string(key) ?? d }

    /// One of `choices` (case-insensitive), lowercased.
    func choice(_ key: String, _ choices: [String]) throws -> String? {
        guard let s = try string(key)?.lowercased() else { return nil }
        guard choices.contains(s) else {
            throw ToolError("\(key) must be one of \(choices.map { "\"\($0)\"" }.joined(separator: ", ")).")
        }
        return s
    }
}

// MARK: - JSON building

extension JSONValue {
    /// A number; NaN and infinities are null.
    static func num(_ x: Double) -> JSONValue { x.isFinite ? .number(x) : .null }
    /// Whole hertz.
    static func hz(_ x: Double) -> JSONValue { num(x.rounded()) }
    /// dB to a tenth.
    static func db(_ x: Float) -> JSONValue { num((Double(x) * 10).rounded() / 10) }
    /// An ISO 8601 time (UTC).
    static func time(_ d: Date) -> JSONValue { .string(d.formatted(.iso8601)) }

    // Schema fragments for the descriptors. The rules (`MCPRadioToolsTests.schemasSuitStrictClients`) keep to
    // what strict clients accept, since some reject the whole tool list over one schema: an object at the top,
    // no `additionalProperties` (unknown arguments are ignored anyway), no empty `required`, and a single
    // `type` per property (`anyOf` for a choice of types).

    /// A tool's arguments: `required` is left out when empty.
    static func inputSchema(properties: [String: JSONValue], required: [String]) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }
    static func schema(_ type: String, _ description: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)].merging(extra) { a, _ in a })
    }
    static func frequencySchema(_ description: String) -> JSONValue {
        .object(["anyOf": .array([.object(["type": .string("number")]), .object(["type": .string("string")])]),
                 "description": .string(description)])
    }
    static func enumSchema(_ values: [String], _ description: String) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(values.map { .string($0) }),
                 "description": .string(description)])
    }
}

extension Optional where Wrapped == JSONValue {
    /// The value, or JSON null.
    var orNull: JSONValue { self ?? .null }
}
