import Foundation
import Security

/// The bearer token and the Origin rule that keep the server to this Mac's own agents.
enum MCPAuth {
    /// 32 random bytes as base64url without padding: 43 characters.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var rng = SystemRandomNumberGenerator()   // also a CSPRNG on macOS
            bytes = bytes.map { _ in rng.next() }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Whether `given` is `expected`, in time that does not depend on where they differ, so the token cannot
    /// be guessed a character at a time. Nothing matches an empty token.
    static func sameToken(_ given: String?, _ expected: String) -> Bool {
        guard let given else { return false }
        let a = Array(given.utf8), b = Array(expected.utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    private static let localOrigins = ["http://localhost", "https://localhost", "http://127.0.0.1",
                                       "https://127.0.0.1", "http://[::1]", "https://[::1]"]

    /// No Origin, `null`, or this Mac over http or https on any port. Anything else is a web page elsewhere
    /// trying to reach the server through the browser.
    static func isLocalOrigin(_ origin: String?) -> Bool {
        guard let origin, !origin.isEmpty, origin != "null" else { return true }
        let o = origin.lowercased()
        return localOrigins.contains { base in
            guard o.hasPrefix(base) else { return false }
            let rest = o.dropFirst(base.count)
            guard let colon = rest.first else { return true }
            let port = rest.dropFirst()
            return colon == ":" && !port.isEmpty && port.allSatisfy(\.isASCIIDigit)
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
