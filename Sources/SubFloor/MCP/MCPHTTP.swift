import Foundation
import Transcription

/// One HTTP/1.1 request as the MCP server reads it.
struct HTTPRequest: Equatable {
    var method: String
    /// The request target as sent, query included.
    var path: String
    /// Header values by lower-cased name. A repeated header's values are joined with ", ".
    var headers: [String: String]
    var body: Data
}

/// What a connection's buffer holds so far.
enum HTTPParseResult: Equatable {
    /// More bytes are needed.
    case incomplete
    /// A whole request, taking the first `consumed` bytes of the buffer (keep-alive: more may follow).
    case request(HTTPRequest, consumed: Int)
    /// The request cannot be served: answer `status` and close the connection.
    case failure(status: Int, message: String)
}

/// Reads requests out of a connection's bytes. Only `Content-Length` bodies: MCP clients send JSON strings.
enum HTTPParser {
    private static let headerEnd = Data("\r\n\r\n".utf8)

    static func parse(_ buffer: Data, maxHeaderBytes: Int = 65_536, maxBodyBytes: Int = 16_777_216) -> HTTPParseResult {
        guard let end = buffer.range(of: headerEnd) else {
            return buffer.count > maxHeaderBytes ? .failure(status: 431, message: "headers too large") : .incomplete
        }
        let headLength = end.lowerBound - buffer.startIndex
        if headLength > maxHeaderBytes { return .failure(status: 431, message: "headers too large") }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return .failure(status: 400, message: "bad request line") }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        if headers["transfer-encoding"] != nil {
            return .failure(status: 400, message: "chunked bodies are not supported; send Content-Length")
        }
        var length = 0
        if let text = headers["content-length"] {
            guard let n = Int(text), n >= 0 else { return .failure(status: 400, message: "bad Content-Length") }
            length = n
        }
        if length > maxBodyBytes { return .failure(status: 413, message: "request too large") }

        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let request = HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers,
                                  body: Data(buffer[bodyStart..<(bodyStart + length)]))
        return .request(request, consumed: bodyStart + length - buffer.startIndex)
    }
}

/// One reply. Always JSON (an empty 202 included), never cached.
struct HTTPResponse {
    var status: Int
    var headers: [(String, String)]
    var body: Data
    /// Ask the client to close the connection after this reply (a request the server could not read).
    var close: Bool

    init(status: Int, headers: [(String, String)] = [], body: Data, close: Bool = false) {
        self.status = status
        self.headers = headers
        self.body = body
        self.close = close
    }

    /// A reply whose body is `value`.
    static func json(_ status: Int, _ value: JSONValue, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: value.encoded())
    }

    /// An HTTP-level refusal: `{"error": message}`.
    static func error(_ status: Int, _ message: String, headers: [(String, String)] = [],
                      close: Bool = false) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: JSONValue.object(["error": .string(message)]).encoded(),
                     close: close)
    }

    /// The value of header `name` (any case), if set.
    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += close ? "Connection: close\r\n" : "Connection: keep-alive\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        default: "Error"
        }
    }
}
