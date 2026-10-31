import Foundation
import Transcription

/// One tool as `tools/list` describes it.
struct MCPToolDescriptor {
    var name: String
    var title: String
    var description: String
    /// A JSON Schema object for the arguments.
    var inputSchema: JSONValue
    /// The tool only reads: it changes nothing on the radio, the recordings or the bookmarks.
    var readOnly: Bool

    /// The `tools/list` entry.
    var listed: JSONValue {
        .object(["name": .string(name), "title": .string(title), "description": .string(description),
                 "inputSchema": inputSchema,
                 "annotations": .object(["title": .string(title), "readOnlyHint": .bool(readOnly)])])
    }
}

/// What a tool call returns: text for every client, the same value structured for clients that take it.
struct MCPToolResult {
    /// The JSON text of the value (after the summary, if any), or the error message.
    var content: String
    var structured: JSONValue?
    var isError: Bool

    /// Success with `value`. A `summary` line, if given, comes before the JSON text.
    static func ok(_ value: JSONValue, summary: String? = nil) -> MCPToolResult {
        let json = String(decoding: value.encoded(), as: UTF8.self)
        return MCPToolResult(content: summary.map { "\($0)\n\(json)" } ?? json, structured: value, isError: false)
    }

    /// A tool error the agent can act on, such as "The radio is stopped: call start_radio first."
    static func failure(_ message: String) -> MCPToolResult {
        MCPToolResult(content: message, structured: nil, isError: true)
    }
}

/// The tools the server offers. Calls run on the main actor, as the user's own actions do.
@MainActor
protocol MCPToolProvider: AnyObject {
    var tools: [MCPToolDescriptor] { get }
    /// Runs tool `name` for `client` (its "name version"). An unknown name is a failure result.
    func call(_ name: String, arguments: [String: JSONValue], client: String) async -> MCPToolResult
}

/// No tools: every call is an unknown tool (the server tests run with it; the app uses `SubFloorTools`).
@MainActor
final class EmptyToolProvider: MCPToolProvider {
    let tools: [MCPToolDescriptor] = []

    func call(_ name: String, arguments: [String: JSONValue], client: String) async -> MCPToolResult {
        .failure("Unknown tool \(name)")
    }
}
