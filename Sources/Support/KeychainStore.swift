import Foundation
import Security

/// API Key 只进 Keychain。不写普通配置文件、不进日志、不进错误信息。
enum KeychainStore {
    private static let service = "com.openvoice.app"
    /// 改名前的旧条目,首次读取时自动迁移
    private static let legacyService = "com.openvoiceinput.app"
    private static let legacyAccount = "openai-api-key"

    static func saveAPIKey(_ key: String) -> Bool {
        saveAPIKey(key, providerID: ModelProvider.defaultOpenAIID)
    }

    static func loadAPIKey() -> String? {
        loadAPIKey(providerID: ModelProvider.defaultOpenAIID)
    }

    static func deleteAPIKey() {
        deleteAPIKey(providerID: ModelProvider.defaultOpenAIID)
    }

    static func saveAPIKey(_ key: String, providerID: String) -> Bool {
        let saved = save(key, service: service, account: account(for: providerID))
        // 在过渡期保留旧账户名，从 Git 回退到旧版 App 时仍能读到密钥。
        if providerID == ModelProvider.defaultOpenAIID {
            return save(key, service: service, account: legacyAccount) && saved
        }
        return saved
    }

    static func loadAPIKey(providerID: String) -> String? {
        let providerAccount = account(for: providerID)
        if let key = load(service: service, account: providerAccount) { return key }

        // 旧版只有一个 OpenAI Key；它自动归入默认 OpenAI 服务商。
        guard providerID == ModelProvider.defaultOpenAIID else { return nil }
        if providerAccount != legacyAccount, let key = load(service: service, account: legacyAccount) {
            _ = save(key, service: service, account: providerAccount)
            return key
        }
        // 迁移旧条目
        if let legacy = load(service: legacyService, account: legacyAccount) {
            _ = save(legacy, service: service, account: providerAccount)
            _ = save(legacy, service: service, account: legacyAccount)
            delete(service: legacyService, account: legacyAccount)
            return legacy
        }
        return nil
    }

    static func deleteAPIKey(providerID: String) {
        delete(service: service, account: account(for: providerID))
        if providerID == ModelProvider.defaultOpenAIID {
            delete(service: service, account: legacyAccount)
        }
    }

    // MARK: - 底层操作

    private static func account(for providerID: String) -> String {
        "provider-api-key:\(providerID)"
    }

    private static func save(_ key: String, service: String, account: String) -> Bool {
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

    private static func load(service: String, account: String) -> String? {
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

    private static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
