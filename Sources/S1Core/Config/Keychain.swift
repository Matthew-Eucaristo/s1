import Foundation
import Security

/// API keys live in the login Keychain, never in `~/.s1/config.json`.
/// One generic-password item per model role, under one service name.
public enum SecretStore {
    public static let defaultService = "com.matthew.s1.api-keys"

    public static func set(_ secret: String, account: String,
                           service: String = defaultService) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        let data = Data(secret.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "s1 API key (\(account))"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw S1Error.aborted("keychain write failed (\(status))")
        }
    }

    public static func get(account: String, service: String = defaultService) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8),
              !s.isEmpty else { return nil }
        return s
    }

    public static func has(account: String, service: String = defaultService) -> Bool {
        get(account: account, service: service) != nil
    }

    @discardableResult
    public static func delete(account: String, service: String = defaultService) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        let status = SecItemDelete(q as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// The model roles s1 wires — each owns one endpoint and one Keychain key.
public enum ModelRole: String, CaseIterable, Sendable {
    /// S1 decision model: typed choice/score/yes-no over current + past state.
    case decision
    /// S1 vision brain (VLM policy) — OpenAI-compatible chat with images.
    case vlm
    /// S1 click grounder — OpenAI-compatible GUI-grounding model.
    case grounder
    /// S2 reasoner — any OpenAI-compatible LLM.
    case s2

    public var envPrefix: String { "S1_\(rawValue.uppercased())" }
}
