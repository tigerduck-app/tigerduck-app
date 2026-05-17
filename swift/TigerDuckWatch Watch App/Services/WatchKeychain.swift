import Foundation
import Security

/// Minimal keychain wrapper for the watch app. Generic-password items
/// scoped to this app's bundle, `.whenUnlockedThisDeviceOnly` so the
/// secret stays on the device (no iCloud restore) and is unreadable
/// while the watch is locked.
///
/// We use raw `SecItem*` rather than Valet because the watch target
/// does not depend on Valet (phone-only Swift package). A 60-line
/// wrapper is preferable to touching `project.pbxproj` to add a
/// package dependency to the watch target.
nonisolated enum WatchKeychain {

    /// Per-app service name — distinct from the phone keychain's service.
    /// Two devices, two stores; this just keeps watch items grouped.
    private static let service = "org.ntust.app.TigerDuck.watch"

    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return set(data, forKey: key)
    }

    @discardableResult
    static func set(_ data: Data, forKey key: String) -> Bool {
        // Update if exists, add otherwise. We never want two items for the
        // same key to coexist (would cause non-deterministic reads).
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound { return false }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func string(forKey key: String) -> String? {
        guard let data = data(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func data(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    @discardableResult
    static func remove(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
