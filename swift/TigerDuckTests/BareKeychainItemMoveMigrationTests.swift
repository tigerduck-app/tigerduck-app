import Foundation
import Security
import Testing
import Valet
@testable import TigerDuck

/// Each test owns a key of its own, so the bare items it adds to the simulator's Keychain reach no
/// other test, and its own defaults and notification center.
@MainActor
struct BareKeychainItemMoveMigrationTests {
    @Test func aBareItemMovesIntoTheStoreOnce() throws {
        let key = Self.uniqueKey()
        defer { SecureStore.delete(key: key) }
        let defaults = try Self.defaults()
        try Self.addBareItem(Data("value".utf8), forKey: key)

        BareKeychainItemMoveMigration.runIfNeeded(defaults: defaults, center: NotificationCenter(), keys: [key])

        #expect(SecureStore.load(key: key) == Data("value".utf8))
        #expect(Self.accessibilityClasses(of: key) == [kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String])

        try Self.addBareItem(Data("later".utf8), forKey: key)
        BareKeychainItemMoveMigration.runIfNeeded(defaults: defaults, center: NotificationCenter(), keys: [key])
        #expect(Self.accessibilityClasses(of: key).count == 2)
    }

    @Test func aValueSavedSinceWinsOverTheBareItem() throws {
        let key = Self.uniqueKey()
        defer { SecureStore.delete(key: key) }
        try Self.addBareItem(Data("old".utf8), forKey: key)
        try SecureStore.save(Data("new".utf8), forKey: key)

        BareKeychainItemMoveMigration.runIfNeeded(defaults: try Self.defaults(), center: NotificationCenter(), keys: [key])

        #expect(SecureStore.load(key: key) == Data("new".utf8))
        #expect(Self.accessibilityClasses(of: key) == [kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String])
    }

    @Test func aBareItemThatCannotMoveYetMovesOnceProtectedDataIsAvailable() throws {
        let key = Self.uniqueKey()
        defer { SecureStore.delete(key: key) }
        let defaults = try Self.defaults()
        let center = NotificationCenter()
        let store = LockablePhoneKeychain()
        store.isLocked = true
        try Self.addBareItem(Data("value".utf8), forKey: key)

        SecureStore.$sharedForTesting.withValue(store) {
            BareKeychainItemMoveMigration.runIfNeeded(defaults: defaults, center: center, keys: [key])
            #expect(store.storedObject(forKey: key) == nil)
            #expect(Self.accessibilityClasses(of: key).count == 1)
            #expect(SecureStore.load(key: key) == Data("value".utf8))

            store.isLocked = false
            center.post(name: BareKeychainItemMoveMigration.readableAgain, object: nil)

            #expect(store.storedObject(forKey: key) == Data("value".utf8))
        }
        #expect(Self.accessibilityClasses(of: key).isEmpty)
    }

    @Test func theStoreReadsABareItemUntilTheMigrationMovesIt() throws {
        let key = Self.uniqueKey()
        defer { SecureStore.delete(key: key) }
        try Self.addBareItem(Data("value".utf8), forKey: key)

        #expect(SecureStore.load(key: key) == Data("value".utf8))
        #expect(try SecureStore.loadIfReadable(key: key) == nil)
        #expect(Self.accessibilityClasses(of: key) == [kSecAttrAccessibleWhenUnlocked as String])

        BareKeychainItemMoveMigration.runIfNeeded(defaults: try Self.defaults(), center: NotificationCenter(), keys: [key])
        #expect(SecureStore.load(key: key) == Data("value".utf8))
        #expect(Self.accessibilityClasses(of: key) == [kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String])
    }

    @Test func theNewestOfTwoBareItemsWins() async throws {
        let key = Self.uniqueKey()
        defer { SecureStore.delete(key: key) }
        try Self.addBareItem(Data("older".utf8), forKey: key)
        // The Keychain keeps modification dates to the second.
        try await Task.sleep(for: .seconds(1.2))
        try Self.addBareItem(Data("newer".utf8), forKey: key, accessGroup: "group.org.ntust.app.TigerDuck")

        #expect(SecureStore.load(key: key) == Data("newer".utf8))
        BareKeychainItemMoveMigration.runIfNeeded(defaults: try Self.defaults(), center: NotificationCenter(), keys: [key])

        #expect(SecureStore.load(key: key) == Data("newer".utf8))
        #expect(Self.accessibilityClasses(of: key) == [kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String])
    }

    @Test func aDeleteTakesTheBareItemToo() throws {
        let key = Self.uniqueKey()
        defer { SecureStore.delete(key: key) }
        try Self.addBareItem(Data("value".utf8), forKey: key)

        SecureStore.delete(key: key)

        #expect(Self.accessibilityClasses(of: key).isEmpty)
    }

    @Test func aValetsItemIsNeitherMovedNorDeletedAsABareOne() throws {
        let key = Self.uniqueKey()
        let valet = Valet.valet(
            with: Identifier(nonEmpty: "org.ntust.app.TigerDuck")!,
            accessibility: .whenUnlockedThisDeviceOnly
        )
        defer { try? valet.removeObject(forKey: key) }
        try valet.setObject(Data("value".utf8), forKey: key)
        let defaults = try Self.defaults()

        SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) {
            BareKeychainItemMoveMigration.runIfNeeded(defaults: defaults, center: NotificationCenter(), keys: [key])
            #expect(SecureStore.load(key: key) == nil)
            SecureStore.delete(key: key)
        }

        #expect(try valet.object(forKey: key) == Data("value".utf8))
    }

    private static func uniqueKey() -> String {
        "BareKeychainItemMoveMigrationTests.\(UUID().uuidString)"
    }

    private static func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: UUID().uuidString))
    }

    private static func addBareItem(_ data: Data, forKey key: String, accessGroup: String? = nil) throws {
        var item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        item[kSecAttrAccessGroup as String] = accessGroup
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
