import Foundation
import Security

/// API Key 只进 Keychain。不写普通配置文件、不进日志、不进错误信息。
enum KeychainStore {
    private static let service = "com.openvoice.app"
    /// 改名前的旧条目,首次读取时自动迁移
    private static let legacyService = "com.openvoiceinput.app"
    private static let account = "openai-api-key"

    static func saveAPIKey(_ key: String) -> Bool {
        save(key, service: service)
    }

    static func loadAPIKey() -> String? {
        if let key = load(service: service) { return key }
        // 迁移旧条目
        if let legacy = load(service: legacyService) {
            _ = save(legacy, service: service)
            delete(service: legacyService)
            return legacy
        }
        return nil
    }

    static func deleteAPIKey() {
        delete(service: service)
    }

    // MARK: - 底层操作

    private static func save(_ key: String, service: String) -> Bool {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private static func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    private static func delete(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
