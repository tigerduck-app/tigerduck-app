import Foundation
import Security
import Testing
import Valet
@testable import TigerDuck

/// iOS launches the app behind a locked screen for a push — above all a
/// Live Activity push-to-start, which hands the app the new activity's
/// update token to register so the server can end the activity when the
/// class does. These pin which secrets such a launch can read.
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
        defer { SecureStore.delete(key: key) }

        try SecureStore.save(Data("value".utf8), forKey: key)

        #expect(accessibilityClasses(of: key) == [afterFirstUnlock])
    }

    @Test(arguments: unlockedOnly)
    func aCredentialStaysUnreadableWhileLocked(key: String) throws {
        defer { SecureStore.delete(key: key) }

        try SecureStore.save(Data("value".utf8), forKey: key)

        #expect(accessibilityClasses(of: key) == [whenUnlocked])
    }

    @Test(arguments: readWhileLocked)
    func aSecretSavedByAnEarlierBuildMovesOnItsFirstRead(key: String) throws {
        defer { SecureStore.delete(key: key) }
        // Where every earlier build wrote every secret.
        let earlier = Valet.valet(
            with: Identifier(nonEmpty: "org.ntust.app.TigerDuck")!,
            accessibility: .whenUnlockedThisDeviceOnly
        )
        try earlier.setObject(Data("value".utf8), forKey: key)

        #expect(SecureStore.load(key: key) == Data("value".utf8))
        #expect(accessibilityClasses(of: key) == [afterFirstUnlock])
    }

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
