import Foundation
import Security

/// Minimal generic-password Keychain wrapper shared by the upload integrations
/// (Google Drive OAuth tokens, GitHub personal access token).
enum KeychainStore {
    private static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // Historical account name kept so existing Google Drive sign-ins
            // stored by earlier builds keep working.
            kSecAttrAccount as String: "oauth-token",
        ]
    }

    static func save(_ data: Data, service: String) {
        delete(service: service)
        var query = baseQuery(service: service)
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(service: String) -> Data? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    static func delete(service: String) {
        SecItemDelete(baseQuery(service: service) as CFDictionary)
    }
}
