import Foundation
import Security
import Valet

enum SecureStore {
    private static let shared = Valet.valet(
        with: Identifier(nonEmpty: "org.ntust.app.TigerDuck")!,
        accessibility: .afterFirstUnlock
    )

    private static let sharedGroup = Valet.sharedGroupValet(
        with: SharedGroupIdentifier(
            groupPrefix: "group",
            nonEmptyGroup: "org.ntust.app.TigerDuck"
        )!,
        accessibility: .afterFirstUnlock
    )

    static func save(_ data: Data, forKey key: String) throws {
        try shared.setObject(data, forKey: key)
        try? sharedGroup.setObject(data, forKey: key)
    }

    static func load(key: String) -> Data? {
        if let value = try? shared.object(forKey: key) {
            return value
        }

        if let value = try? sharedGroup.object(forKey: key) {
            try? shared.setObject(value, forKey: key)
            return value
        }

        guard let legacyValue = legacyLoad(key: key) else {
            return nil
        }

        try? save(legacyValue, forKey: key)
        legacyDelete(key: key)
        return legacyValue
    }

    static func delete(key: String) {
        try? shared.removeObject(forKey: key)
        try? sharedGroup.removeObject(forKey: key)
        legacyDelete(key: key)
    }

    private static func legacyLoad(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return nil
        }

        return result as? Data
    }

    private static func legacyDelete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)
    }
}
