import Foundation
import SubFloorCore
import Transcription

/// One SubFloor tool: what `tools/list` shows, and what a call runs. `run` returns the result's fields
/// (`"ok": true` is added) or throws a `ToolError` whose message is the tool error.
struct SubFloorTool {
    var descriptor: MCPToolDescriptor
    var run: @MainActor (SubFloorTools, ToolArguments, _ client: String) async throws -> [String: JSONValue]

    init(_ name: String, title: String, readOnly: Bool, description: String,
         properties: [String: JSONValue] = [:], required: [String] = [],
         run: @escaping @MainActor (SubFloorTools, ToolArguments, _ client: String) async throws -> [String: JSONValue]) {
        let schema: JSONValue = .object(["type": .string("object"), "properties": .object(properties),
                                         "required": .array(required.map { .string($0) }),
                                         "additionalProperties": .bool(false)])
        descriptor = MCPToolDescriptor(name: name, title: title, description: description, inputSchema: schema,
                                       readOnly: readOnly)
        self.run = run
    }
}

/// A failed precondition or a bad argument: `message` says what to do, and is the tool error's text.
struct ToolError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

/// SubFloor's tools over the app's model. Read-only tools run at once; the others run one at a time, in the
/// order they were called (`withRadio`).
@MainActor
final class SubFloorTools: MCPToolProvider {
    let model: AppModel
    /// The agents connected to the server, for `get_status` (set by the app from `MCPServer.connectedClients`).
    var connectedClients: () -> [String] = { [] }
    let tools: [MCPToolDescriptor]
    private let registry: [String: SubFloorTool]
    private var radioBusy = false
    private var radioWaiters: [CheckedContinuation<Void, Never>] = []

    init(model: AppModel) {
        self.model = model
        let all = Self.radioTools + Self.bookmarkTools
        tools = all.map(\.descriptor)
        registry = Dictionary(all.map { ($0.descriptor.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func call(_ name: String, arguments: [String: JSONValue], client: String) async -> MCPToolResult {
        guard let tool = registry[name] else { return .failure("Unknown tool \(name)") }
        let args = ToolArguments(arguments)
        let run = { () async -> MCPToolResult in
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
        return tool.descriptor.readOnly ? await run() : await withRadio(run)
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

    // Schema fragments for the descriptors.
    static func schema(_ type: String, _ description: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)].merging(extra) { a, _ in a })
    }
    static func frequencySchema(_ description: String) -> JSONValue {
        .object(["type": .array([.string("number"), .string("string")]), "description": .string(description)])
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
