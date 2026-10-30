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
    static let readWhileLocked = [
        AuthTokenManager.accessTokenKey,
        AuthTokenManager.refreshTokenKey,
        AuthTokenManager.expiresAtKey,
        AppConstants.KeychainKeys.pushDeviceId,
        DebugEndpointStore.keychainKey,
    ]

    static let readWhileLockedSinceTheMove = [AuthTokenManager.refreshTokenUsesKey, AuthTokenManager.departingSessionKey]

    static let unlockedOnly = [
        AppConstants.KeychainKeys.studentId,
        AppConstants.KeychainKeys.password,
        AppConstants.KeychainKeys.libraryPassword,
        AppConstants.KeychainKeys.moodleToken,
    ]

    @Test(arguments: readWhileLocked + readWhileLockedSinceTheMove)
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
        try earlierBuildsValet.setObject(Data("old".utf8), forKey: key)

        try SecureStore.save(Data("new".utf8), forKey: key)

        #expect(SecureStore.load(key: key) == Data("new".utf8))
        #expect(accessibilityClasses(of: key) == [afterFirstUnlock])
    }

    /// Whether a locked phone also reports an item it does not hold as
    /// unreadable. A simulator cannot say, so the locked tests take both.
    static let absentReadsFailWhileLocked = [false, true]

    @Test(arguments: readWhileLocked, absentReadsFailWhileLocked)
    func aMovedSecretCanBeReadAndReplacedWhileLocked(key: String, absentReadsFail: Bool) throws {
        SecureStore.delete(key: key)
        defer { SecureStore.delete(key: key) }
        let earlierBuilds = LockablePhoneKeychain(absentReadsFailWhileLocked: absentReadsFail)

        try SecureStore.$sharedForTesting.withValue(earlierBuilds) {
            try earlierBuilds.setObject(Data("old".utf8), forKey: key)
            _ = SecureStore.load(key: key)

            earlierBuilds.isLocked = true
            #expect(SecureStore.load(key: key) == Data("old".utf8))
            try SecureStore.save(Data("rotated".utf8), forKey: key)
            #expect(SecureStore.load(key: key) == Data("rotated".utf8))
        }
    }

    @Test(arguments: absentReadsFailWhileLocked)
    func aLockedLaunchAfterTheUpdateCountsTheRefreshTokensSends(absentReadsFail: Bool) async throws {
        let keys = [
            AuthTokenManager.accessTokenKey, AuthTokenManager.refreshTokenKey,
            AuthTokenManager.expiresAtKey, AuthTokenManager.refreshTokenUsesKey,
        ]
        keys.forEach { SecureStore.delete(key: $0) }
        defer { keys.forEach { SecureStore.delete(key: $0) } }
        let earlierBuilds = LockablePhoneKeychain(absentReadsFailWhileLocked: absentReadsFail)
        let refreshURL = SettingsAPIStub.uniqueBaseURL().appendingPathComponent("auth/refresh")
        SettingsAPIStub.enqueue(.noReply, for: refreshURL)
        SettingsAPIStub.enqueue(.noReply, for: refreshURL)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]

        try await SecureStore.$sharedForTesting.withValue(earlierBuilds) {
            for (key, value) in [
                (AuthTokenManager.accessTokenKey, "A0"), (AuthTokenManager.refreshTokenKey, "R0"),
                (AuthTokenManager.expiresAtKey, "0"),
            ] {
                try SecureStore.save(Data(value.utf8), forKey: key)
            }
            earlierBuilds.isLocked = true
            let manager = AuthTokenManager(
                baseURLProvider: { refreshURL.deletingLastPathComponent().deletingLastPathComponent() },
                deviceUUID: "test-device", session: URLSession(configuration: config), beginBackgroundTask: { {} }
            )

            #expect(await manager.validAccessToken() == nil)

            #expect(SettingsAPIStub.requests(for: refreshURL).count == 2)
            #expect(SecureStore.load(key: AuthTokenManager.refreshTokenUsesKey) == Data("2".utf8))
        }
    }

    @Test(arguments: readWhileLocked, absentReadsFailWhileLocked)
    func aSecretNotYetMovedIsKeptForAnUnlockedRead(key: String, absentReadsFail: Bool) throws {
        SecureStore.delete(key: key)
        defer { SecureStore.delete(key: key) }
        let earlierBuilds = LockablePhoneKeychain(absentReadsFailWhileLocked: absentReadsFail)

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

    @Test func aReadWhileLockedThrowsAndAnAbsentItemDoesNot() throws {
        let key = AppConstants.KeychainKeys.studentId
        SecureStore.delete(key: key)
        defer { SecureStore.delete(key: key) }
        let shared = LockablePhoneKeychain()

        try SecureStore.$sharedForTesting.withValue(shared) {
            #expect(try SecureStore.loadIfReadable(key: key) == nil)
            try SecureStore.save(Data("value".utf8), forKey: key)
            shared.isLocked = true

            #expect(throws: KeychainError.couldNotAccessKeychain) {
                try SecureStore.loadIfReadable(key: key)
            }

            shared.isLocked = false
            #expect(try SecureStore.loadIfReadable(key: key) == Data("value".utf8))
        }
    }

    @Test(arguments: readWhileLocked, absentReadsFailWhileLocked)
    func aSecretNotYetMovedIsUnreadableWhileLocked(key: String, absentReadsFail: Bool) throws {
        SecureStore.delete(key: key)
        defer { SecureStore.delete(key: key) }
        let earlierBuilds = LockablePhoneKeychain(absentReadsFailWhileLocked: absentReadsFail)

        try SecureStore.$sharedForTesting.withValue(earlierBuilds) {
            try earlierBuilds.setObject(Data("real".utf8), forKey: key)
            earlierBuilds.isLocked = true

            #expect(throws: KeychainError.couldNotAccessKeychain) {
                try SecureStore.loadIfReadable(key: key)
            }

            earlierBuilds.isLocked = false
            #expect(try SecureStore.loadIfReadable(key: key) == Data("real".utf8))
        }
    }

    @Test(arguments: readWhileLocked)
    func aSecretNeverStoredReadsAbsentWhileLocked(key: String) throws {
        SecureStore.delete(key: key)
        defer { SecureStore.delete(key: key) }
        let earlierBuilds = LockablePhoneKeychain()

        try SecureStore.$sharedForTesting.withValue(earlierBuilds) {
            earlierBuilds.isLocked = true
            let value = try SecureStore.loadIfReadable(key: key)
            #expect(value == nil)
        }
    }

    private let earlierBuildsValet = Valet.valet(
        with: Identifier(nonEmpty: "org.ntust.app.TigerDuck")!,
        accessibility: .whenUnlockedThisDeviceOnly
    )

    private let afterFirstUnlock = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    private let whenUnlocked = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String

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
/// (`errSecInteractionNotAllowed`). Deletes go through even when locked, so
/// a test catches code that drops a copy it could not read.
final class LockablePhoneKeychain: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var locked = false

    /// Whether, locked, reading an item it does not hold fails too, rather
    /// than reading as `itemNotFound`. Whether a locked phone tells an
    /// absent item from an unreadable one is something a simulator cannot
    /// show, so a test can take either answer.
    private let absentReadsFailWhileLocked: Bool

    init(absentReadsFailWhileLocked: Bool = false) {
        self.absentReadsFailWhileLocked = absentReadsFailWhileLocked
    }

    var isLocked: Bool {
        get { lock.withLock { locked } }
        set { lock.withLock { locked = newValue } }
    }

    func storedObject(forKey key: String) -> Data? {
        lock.withLock { items[key] }
    }

    func object(forKey key: String) throws -> Data {
        try lock.withLock {
            if locked, items[key] != nil || absentReadsFailWhileLocked {
                throw KeychainError.couldNotAccessKeychain
            }
            guard let item = items[key] else { throw KeychainError.itemNotFound }
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
