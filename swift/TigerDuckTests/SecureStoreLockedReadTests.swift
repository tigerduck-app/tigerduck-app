import Foundation
import Security
import Testing
import Valet
@testable import TigerDuck

/// iOS launches the app behind a locked screen for a push — above all a
/// Live Activity push-to-start, which hands the app the new activity's
/// update token to register so the server can end the activity when the
/// class does. These pin which secrets such a launch can read.
///
/// A simulator never locks, so the tests of the locked launch itself swap
/// ``LockablePhoneKeychain`` in for `SecureStore`'s
/// `.whenUnlockedThisDeviceOnly` valet and lock that.
@Suite(.serialized)
struct SecureStoreLockedReadTests {
    /// What registering a push-started Live Activity reads: the backend
    /// session, the device id, and the endpoint the device was pointed at.
    static let readWhileLocked = [
        AuthTokenManager.accessTokenKey,
        AuthTokenManager.refreshTokenKey,
        AuthTokenManager.expiresAtKey,
        AppConstants.KeychainKeys.pushDeviceId,
        DebugEndpointStore.keychainKey,
    ]

    /// Nothing that runs in the background needs these.
    static let unlockedOnly = [
        AppConstants.KeychainKeys.studentId,
        AppConstants.KeychainKeys.password,
        AppConstants.KeychainKeys.libraryPassword,
        AppConstants.KeychainKeys.moodleToken,
    ]

    @Test(arguments: readWhileLocked)
    func aSecretTheBackgroundNeedsIsReadableAfterFirstUnlock(key: String) throws {
        SecureStore.delete(key: key)
        defer { SecureStore.delete(key: key) }

        try SecureStore.save(Data("value".utf8), forKey: key)

        #expect(accessibilityClasses(of: key) == [afterFirstUnlock])
    }

    @Test(arguments: unlockedOnly)
    func aCredentialStaysUnreadableWhileLocked(key: String) throws {
        SecureStore.delete(key: key)
        defer { SecureStore.delete(key: key) }

        try SecureStore.save(Data("value".utf8), forKey: key)

        #expect(accessibilityClasses(of: key) == [whenUnlocked])
    }

    @Test(arguments: readWhileLocked)
    func aSecretSavedByAnEarlierBuildMovesOnItsFirstRead(key: String) throws {
        SecureStore.delete(key: key)
        defer { SecureStore.delete(key: key) }
        try earlierBuildsValet.setObject(Data("value".utf8), forKey: key)

        #expect(SecureStore.load(key: key) == Data("value".utf8))
        #expect(accessibilityClasses(of: key) == [afterFirstUnlock])
    }

    @Test(arguments: readWhileLocked)
    func aSaveOverAnEarlierBuildsReadableCopyReplacesIt(key: String) throws {
        SecureStore.delete(key: key)
        defer { SecureStore.delete(key: key) }
        // Unlocked, the earlier build's copy is readable: the save is the
        // newer value and takes its place. (Locked, the save is refused so
        // a stand-in cannot bury it: `aSecretNotYetMovedIsKeptForAnUnlockedRead`.)
        try earlierBuildsValet.setObject(Data("old".utf8), forKey: key)

        try SecureStore.save(Data("new".utf8), forKey: key)

        #expect(SecureStore.load(key: key) == Data("new".utf8))
        #expect(accessibilityClasses(of: key) == [afterFirstUnlock])
    }

    // MARK: Behind a locked screen

    /// The case the move is for. Once moved, a locked launch reads the
    /// session and the device id, and when it refreshes the session, the
    /// rotated refresh token is saved; lost, the next refresh would send
    /// the spent one.
    @Test(arguments: readWhileLocked)
    func aMovedSecretCanBeReadAndReplacedWhileLocked(key: String) throws {
        SecureStore.delete(key: key)
        defer { SecureStore.delete(key: key) }
        let earlierBuilds = LockablePhoneKeychain()

        try SecureStore.$sharedForTesting.withValue(earlierBuilds) {
            try earlierBuilds.setObject(Data("old".utf8), forKey: key)
            _ = SecureStore.load(key: key)  // the first unlocked read moves it

            earlierBuilds.isLocked = true
            #expect(SecureStore.load(key: key) == Data("old".utf8))
            try SecureStore.save(Data("rotated".utf8), forKey: key)
            #expect(SecureStore.load(key: key) == Data("rotated".utf8))
        }
    }

    /// The first launch after an update is often a locked one. It cannot
    /// read what an earlier build kept, so it takes the secret for absent —
    /// `PushIdentity` mints a fresh device id and saves it. That stand-in
    /// must not take the real value's place.
    @Test(arguments: readWhileLocked)
    func aSecretNotYetMovedIsKeptForAnUnlockedRead(key: String) throws {
        SecureStore.delete(key: key)
        defer { SecureStore.delete(key: key) }
        let earlierBuilds = LockablePhoneKeychain()

        try SecureStore.$sharedForTesting.withValue(earlierBuilds) {
            try earlierBuilds.setObject(Data("real".utf8), forKey: key)
            earlierBuilds.isLocked = true

            #expect(SecureStore.load(key: key) == nil)
            #expect(throws: KeychainError.couldNotAccessKeychain) {
                try SecureStore.save(Data("stand-in".utf8), forKey: key)
            }
            #expect(SecureStore.load(key: key) == nil)
            #expect(earlierBuilds.storedObject(forKey: key) == Data("real".utf8))

            earlierBuilds.isLocked = false
            #expect(SecureStore.load(key: key) == Data("real".utf8))
            #expect(earlierBuilds.storedObject(forKey: key) == nil)

            // Moved: the next locked launch reads it.
            earlierBuilds.isLocked = true
            #expect(SecureStore.load(key: key) == Data("real".utf8))
        }
    }

    @Test(arguments: unlockedOnly)
    func aCredentialCanBeNeitherReadNorSavedWhileLocked(key: String) throws {
        SecureStore.delete(key: key)
        defer { SecureStore.delete(key: key) }
        let shared = LockablePhoneKeychain()

        try SecureStore.$sharedForTesting.withValue(shared) {
            try SecureStore.save(Data("value".utf8), forKey: key)
            shared.isLocked = true

            #expect(SecureStore.load(key: key) == nil)
            #expect(throws: KeychainError.couldNotAccessKeychain) {
                try SecureStore.save(Data("other".utf8), forKey: key)
            }

            shared.isLocked = false
            #expect(SecureStore.load(key: key) == Data("value".utf8))
        }
    }

    /// Where every earlier build wrote every secret.
    private let earlierBuildsValet = Valet.valet(
        with: Identifier(nonEmpty: "org.ntust.app.TigerDuck")!,
        accessibility: .whenUnlockedThisDeviceOnly
    )

    private let afterFirstUnlock = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    private let whenUnlocked = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String

    /// The protection class of every keychain item stored under `key`.
    private func accessibilityClasses(of key: String) -> [String] {
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

/// Replaces `SecureStore`'s `.whenUnlockedThisDeviceOnly` valet in a test,
/// and can be locked, which a simulator cannot be.
///
/// Locked, it fails the way that valet does behind a locked screen: reading
/// an item it holds, or writing one, is `couldNotAccessKeychain`
/// (`errSecInteractionNotAllowed`). An item it does not hold still reads as
/// `itemNotFound`, which is what lets `SecureStore` tell an unreadable copy
/// from none. Deletes go through even when locked, so a test catches code
/// that drops a copy it could not read.
private final class LockablePhoneKeychain: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var locked = false

    var isLocked: Bool {
        get { lock.withLock { locked } }
        set { lock.withLock { locked = newValue } }
    }

    /// What it holds for `key`, lock or not.
    func storedObject(forKey key: String) -> Data? {
        lock.withLock { items[key] }
    }

    func object(forKey key: String) throws -> Data {
        try lock.withLock {
            guard let item = items[key] else { throw KeychainError.itemNotFound }
            guard !locked else { throw KeychainError.couldNotAccessKeychain }
            return item
        }
    }

    func setObject(_ object: Data, forKey key: String) throws {
        try lock.withLock {
            guard !locked else { throw KeychainError.couldNotAccessKeychain }
            items[key] = object
        }
    }

    func removeObject(forKey key: String) throws {
        lock.withLock { items[key] = nil }
    }

    func removeAllObjects() throws {
        lock.withLock { items.removeAll() }
    }
}
