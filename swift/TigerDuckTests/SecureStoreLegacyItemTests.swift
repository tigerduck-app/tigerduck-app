import Foundation
import Security
import Testing
import Valet
@testable import TigerDuck

struct SecureStoreLegacyItemTests {
    @Test func aSecretFromBeforeV13StaysAfterItsFirstRead() throws {
        let key = Self.uniqueKey()
        defer { SecureStore.delete(key: key) }
        try Self.addBareItem(Data("value".utf8), forKey: key)

        #expect(SecureStore.load(key: key) == Data("value".utf8))
        #expect(SecureStore.load(key: key) == Data("value".utf8))
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

    private static func addBareItem(_ data: Data, forKey key: String) throws {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        try #require(status == errSecSuccess, "SecItemAdd failed with \(status)")
    }

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
