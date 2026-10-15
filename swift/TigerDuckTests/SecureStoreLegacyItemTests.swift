import Foundation
import Security
import Testing
import Valet
@testable import TigerDuck

/// Builds before v1.3 kept each secret as a bare generic-password item, matched on its account
/// alone, and the first read moves it into `SecureStore`'s valet
/// (https://github.com/tigerduck-app/tigerduck-app/issues/505). Each test uses a key of its own
/// in the simulator's real keychain, so it cannot meet another suite's items.
struct SecureStoreLegacyItemTests {
    @Test func aSecretFromBeforeV13StaysAfterItsFirstRead() throws {
        let key = Self.uniqueKey()
        defer { SecureStore.delete(key: key) }
        try Self.addBareItem(Data("value".utf8), forKey: key)

        #expect(SecureStore.load(key: key) == Data("value".utf8))
        #expect(SecureStore.load(key: key) == Data("value".utf8))
        // The bare item is gone, and the valet's copy is the only one left.
        #expect(Self.accessibilityClasses(of: key) == [kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String])
    }

    @Test func aSaveOverASecretFromBeforeV13KeepsTheNewValue() throws {
        let key = Self.uniqueKey()
        defer { SecureStore.delete(key: key) }
        try Self.addBareItem(Data("old".utf8), forKey: key)
        _ = SecureStore.load(key: key)

        try SecureStore.save(Data("new".utf8), forKey: key)

        #expect(SecureStore.load(key: key) == Data("new".utf8))
    }

    @Test func aDeleteTakesTheBareItemToo() throws {
        let key = Self.uniqueKey()
        defer { SecureStore.delete(key: key) }
        try Self.addBareItem(Data("value".utf8), forKey: key)

        SecureStore.delete(key: key)

        #expect(Self.accessibilityClasses(of: key).isEmpty)
        #expect(SecureStore.load(key: key) == nil)
    }

    /// A valet's item carries the key as its account too, but `load` reads each valet by name. Taken
    /// for an earlier build's item, it would be moved, and deleted where it was: under a test's
    /// stand-in keychain, another suite's item in the simulator's keychain.
    @Test func aValetsItemIsNeitherReadNorDeletedAsAnEarlierBuildsOne() throws {
        let key = Self.uniqueKey()
        let valet = Valet.valet(
            with: Identifier(nonEmpty: "org.ntust.app.TigerDuck")!,
            accessibility: .whenUnlockedThisDeviceOnly
        )
        defer { try? valet.removeObject(forKey: key) }
        try valet.setObject(Data("value".utf8), forKey: key)

        SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) {
            #expect(SecureStore.load(key: key) == nil)
            SecureStore.delete(key: key)
        }

        #expect(try valet.object(forKey: key) == Data("value".utf8))
    }

    private static func uniqueKey() -> String {
        "SecureStoreLegacyItemTests.\(UUID().uuidString)"
    }

    /// What `KeychainManager.save` wrote before v1.3: no service, no access group, no class.
    private static func addBareItem(_ data: Data, forKey key: String) throws {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        try #require(status == errSecSuccess, "SecItemAdd failed with \(status)")
    }

    /// The protection class of every keychain item stored under `key`.
    private static func accessibilityClasses(of key: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return [] }
        return items.compactMap { $0[kSecAttrAccessible as String] as? String }
    }
}
