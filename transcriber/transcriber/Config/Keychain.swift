import Foundation
import Security

/// Minimal Keychain wrapper for the backend API key.
///
/// The key is never checked into the repo: it arrives either from a gitignored
/// `Config.plist` on first launch or from the in-app Settings screen.
nonisolated enum Keychain {
    static func string(for account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        let query = baseQuery(account: account)
        guard let value, !value.isEmpty else {
            return SecItemDelete(query as CFDictionary) != errSecParam
        }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.gotham.transcriber.config",
            kSecAttrAccount as String: account,
        ]
    }
}
