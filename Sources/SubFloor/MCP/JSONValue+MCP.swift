import Foundation
import Transcription

/// Reading and writing the JSON-RPC messages the MCP server exchanges.
extension JSONValue {
    /// The member `key` of an object; nil for a missing key or a value that is not an object.
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var double: Double? { if case .number(let n) = self { n } else { nil } }
    var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }

    /// Compact JSON with sorted keys. Integral numbers are written without a fraction (`1`, not `1.0`), so
    /// JSON-RPC ids come back as they were sent. A value JSON cannot hold (NaN, infinity) is written as `null`.
    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    /// `data` read as JSON, or nil when it is not JSON.
    static func decode(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
