import Foundation
import Security

/// Where a secret lives (the OpenRouter key, the MCP token). It is kept out of `UserDefaults`, the session and
/// every log.
protocol APIKeyStore: AnyObject {
    /// The stored key, or nil when there is none or it could not be read.
    func load() -> String?
    /// The stored key, telling "there is none" apart from "it could not be read" (a denied Keychain prompt,
    /// a locked keychain). The default reads `load()`, so it never fails.
    func loadResult() -> APIKeyLoadResult
    /// Stores `key`, replacing any earlier one.
    func save(_ key: String) throws
    /// Removes the key. Removing when there is none is not an error.
    func remove() throws
}

/// What reading a stored key found.
enum APIKeyLoadResult: Equatable {
    case found(String)
    /// There is no stored key.
    case notFound
    /// The key could not be read; the `OSStatus` says why.
    case failed(OSStatus)
}

extension APIKeyStore {
    func loadResult() -> APIKeyLoadResult {
        load().map { .found($0) } ?? .notFound
    }
}

/// Why a key could not be imported from a `.env` file.
enum APIKeyImportError: Error, Equatable {
    /// The file has no `OPENROUTER=` or `OPENROUTER_API_KEY=` line with a value.
    case noKey
}

/// A Keychain operation failed. Carries the `OSStatus`, never the key.
struct KeychainError: Error, Equatable {
    let status: OSStatus
}

/// The key as a generic password in the user's login Keychain, under `service` and `account`.
final class KeychainAPIKeyStore: APIKeyStore {
    static let openRouterService = "app.subfloor.SubFloor.openrouter"
    static let openRouterAccount = "api-key"

    let service: String
    let account: String

    /// The defaults are the OpenRouter key's item.
    init(service: String = KeychainAPIKeyStore.openRouterService,
         account: String = KeychainAPIKeyStore.openRouterAccount) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() -> String? {
        if case .found(let key) = loadResult() { return key }
        return nil
    }

    func loadResult() -> APIKeyLoadResult {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
                return .failed(errSecDecode)
            }
            return .found(key)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed(status)
        }
    }

    func save(_ key: String) throws {
        let data = Data(key.utf8)
        var add = query
        add[kSecValueData as String] = data
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// The key held in memory only. The designated `AppModel` init uses it by default, so tests never touch
/// the Keychain.
final class MemoryAPIKeyStore: APIKeyStore {
    private var key: String?

    init(key: String? = nil) { self.key = key }

    func load() -> String? { key }
    func save(_ key: String) throws { self.key = key }
    func remove() throws { key = nil }
}
