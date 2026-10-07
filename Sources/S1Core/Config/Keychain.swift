import Synchronization
import Foundation
import Security

/// API keys live in the login Keychain, never in `~/.s1/config.json`.
/// One generic-password item per connected provider, under one service name.
///
/// macOS asks before an app reads an item's *secret*; asking only whether an
/// item exists never prompts. So `has` reads attributes only, and `get` reads
/// each secret at most once per process (cached until `set`/`delete`). With
/// a stable code signature, "Always Allow" on that one prompt sticks across
/// updates.
public enum SecretStore {
    public static let defaultService = "com.matthew.s1.api-keys"

    private static let cache = Mutex<[String: String]>([:])
    private static func key(_ service: String, _ account: String) -> String { service + "/" + account }

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
        cache.withLock { $0[key(service, account)] = secret }
    }

    public static func get(account: String, service: String = defaultService) -> String? {
        if let hit = cache.withLock({ $0[key(service, account)] }) { return hit }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8),
              !s.isEmpty else { return nil }
        cache.withLock { $0[key(service, account)] = s }
        return s
    }

    /// Whether a key is stored, without reading it (never prompts).
    public static func has(account: String, service: String = defaultService) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func delete(account: String, service: String = defaultService) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        let status = SecItemDelete(q as CFDictionary)
        cache.withLock { _ = $0.removeValue(forKey: key(service, account)) }
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
