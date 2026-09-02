import Foundation
import Security

/// Stores the user's OpenAI API key in the macOS Keychain — never in
/// config.json, unlike every other setting this app persists. A generic
/// password item scoped to this app's bundle identifier; only the Settings
/// UI reads or writes it.
enum OpenAIKeychain {
    private static let service = "com.gabrieImoreira.coruja"
    private static let account = "openai_api_key"

    enum KeychainError: Error, CustomStringConvertible {
        case saveFailed(OSStatus)

        var description: String {
            switch self {
            case .saveFailed(let status):
                return "não foi possível salvar a chave no Keychain (status \(status))"
            }
        }
    }

    static func get() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Delete-then-add rather than update: simpler than juggling
        // SecItemUpdate's separate query/attributes-to-change dictionaries
        // for a single-field item like this one.
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
