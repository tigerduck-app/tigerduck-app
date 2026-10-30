import Foundation
import Security
import Valet

nonisolated enum SecureStore {
    /// Per-app valet at the strictest class our usage allows.
    ///
    /// Re-auth, settings reads and library QR refresh run while the app is active, and no
    /// extension needs these secrets: the Live Activity renders the snapshot its content state
    /// carries. `.whenUnlockedThisDeviceOnly` keeps items out of an iCloud
    /// Keychain restore to a new device, and background work behind a locked screen cannot read
    /// them, which the threat model accepts. The few secrets a locked-screen launch needs live
    /// in ``readableWhileLocked``.
    private static var shared: any KeychainStore {
        sharedForTesting ?? sharedValet
    }

    private static let sharedValet = Valet.valet(
        with: Identifier(nonEmpty: "org.ntust.app.TigerDuck")!,
        accessibility: .whenUnlockedThisDeviceOnly
    )

    @TaskLocal static var sharedForTesting: (any KeychainStore)?

    /// The secrets a launch behind a locked screen has to read.
    ///
    /// A push launches the app in the background, usually on a locked phone. Above all, a Live
    /// Activity push-to-start hands over the update token the server needs to end the activity
    /// after class, and registering it reads the backend session, device id and endpoint
    /// override. In ``shared`` they are unreadable then: the launch would act signed out, mint
    /// a throwaway device id, use the default endpoint and leave the activity up. NTUST, Moodle
    /// and library credentials stay in ``shared``: no background work needs them.
    private static let readableWhileLockedKeys: Set<String> = [
        AuthTokenManager.accessTokenKey,
        AuthTokenManager.refreshTokenKey,
        AuthTokenManager.expiresAtKey,
        AuthTokenManager.refreshTokenUsesKey,
        AuthTokenManager.departingSessionKey,
        AppConstants.KeychainKeys.pushDeviceId,
        DebugEndpointStore.keychainKey,
    ]

    private static let neverInShared: Set<String> = [
        AuthTokenManager.refreshTokenUsesKey, AuthTokenManager.departingSessionKey,
    ]

    /// Home of ``readableWhileLockedKeys``. `.afterFirstUnlockThisDeviceOnly`
    /// is readable once the phone has been unlocked after a restart, and
    /// like ``shared`` never leaves the device.
    private static let readableWhileLocked = Valet.valet(
        with: Identifier(nonEmpty: "org.ntust.app.TigerDuck")!,
        accessibility: .afterFirstUnlockThisDeviceOnly
    )

    private static func home(forKey key: String) -> any KeychainStore {
        readableWhileLockedKeys.contains(key) ? readableWhileLocked : shared
    }

    private static let legacyShared = Valet.valet(
        with: Identifier(nonEmpty: "org.ntust.app.TigerDuck")!,
        accessibility: .afterFirstUnlock
    )

    private static let legacySharedGroup = Valet.sharedGroupValet(
        with: SharedGroupIdentifier(
            groupPrefix: "group",
            nonEmptyGroup: "org.ntust.app.TigerDuck"
        )!,
        accessibility: .afterFirstUnlock
    )

    static func save(_ data: Data, forKey key: String) throws {
        let home = home(forKey: key)
        if home !== shared, !neverInShared.contains(key), (try? home.object(forKey: key)) == nil {
            try requireNoUnreadableCopyInShared(forKey: key)
        }
        try home.setObject(data, forKey: key)
        for store in [shared, legacyShared, legacySharedGroup] where store !== home {
            try? store.removeObject(forKey: key)
        }
    }

    private static func requireNoUnreadableCopyInShared(forKey key: String) throws {
        do {
            _ = try shared.object(forKey: key)
        } catch KeychainError.itemNotFound {
            return
        }
    }

    /// ``load(key:)``, but a throw where it answers nil because the Keychain cannot be read now,
    /// as before the first unlock after a restart, rather than because nothing is stored. An
    /// earlier build's copy in ``shared``, which a locked launch cannot read or move, counts too;
    /// a bare item from before v1.3.1 does not.
    static func loadIfReadable(key: String) throws -> Data? {
        if let value = loadSaved(key: key) { return value }
        let home = home(forKey: key)
        if home !== shared { try requireNoUnreadableCopyInShared(forKey: key) }
        do {
            return try home.object(forKey: key)
        } catch KeychainError.itemNotFound {
            return nil
        }
    }

    /// Falls back to the newest bare item, which `BareKeychainItemMoveMigration` moves only once
    /// the phone is unlocked; a launch behind the lock screen still reads it after the unlock.
    static func load(key: String) -> Data? {
        loadSaved(key: key) ?? legacyItems(key: key)?.lazy.compactMap { try? readLegacyItem($0) }.first
    }

    private static func loadSaved(key: String) -> Data? {
        let home = home(forKey: key)
        if let value = try? home.object(forKey: key) {
            return value
        }

        if home !== shared, let value = try? shared.object(forKey: key) {
            if (try? home.setObject(value, forKey: key)) != nil {
                try? shared.removeObject(forKey: key)
            }
            return value
        }

        if let value = try? legacyShared.object(forKey: key) {
            if (try? home.setObject(value, forKey: key)) != nil {
                try? legacyShared.removeObject(forKey: key)
            }
            return value
        }

        if let value = try? legacySharedGroup.object(forKey: key) {
            if (try? home.setObject(value, forKey: key)) != nil {
                try? legacySharedGroup.removeObject(forKey: key)
            }
            return value
        }
        return nil
    }

    static func delete(key: String) {
        try? readableWhileLocked.removeObject(forKey: key)
        try? shared.removeObject(forKey: key)
        try? legacyShared.removeObject(forKey: key)
        try? legacySharedGroup.removeObject(forKey: key)
        legacyDelete(key: key)
    }

    static func deleteReportingSuccess(key: String) -> Bool {
        var ok = true
        for store in [readableWhileLocked, shared, legacyShared, legacySharedGroup] {
            do {
                try store.removeObject(forKey: key)
            } catch {
                let nsError = error as NSError
                let isMissing = (nsError.domain == NSOSStatusErrorDomain && nsError.code == Int(errSecItemNotFound))
                if !isMissing { ok = false }
            }
        }
        return legacyDelete(key: key) && ok
    }

    static func removeAll(preserving preservedKeys: Set<String> = []) {
        let preserved: [String: Data] = preservedKeys.reduce(into: [:]) { acc, key in
            if let value = load(key: key) { acc[key] = value }
        }
        for store in [readableWhileLocked, shared, legacyShared, legacySharedGroup] {
            try? store.removeAllObjects()
        }
        for (key, value) in preserved {
            try? save(value, forKey: key)
        }
    }

    /// A sign-out or a reinstall's purge before `BareKeychainItemMoveMigration` has moved the bare
    /// items deletes them too, or that migration would bring the departed account back.
    @discardableResult
    private static func legacyDelete(key: String) -> Bool {
        guard let items = legacyItems(key: key) else { return false }
        return items.map(deleteLegacyItem).allSatisfy { $0 }
    }

    /// The bare item's value, nil when it is gone, or a throw when it cannot be read now.
    static func readLegacyItem(_ item: Data) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: item,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.couldNotAccessKeychain
        }
    }

    @discardableResult
    static func deleteLegacyItem(_ item: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: item,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// The items builds up to v1.3.0 saved for `key` without a service, newest first, as persistent
    /// references; nil when the Keychain cannot list them now.
    static func legacyItems(key: String) -> [Data]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return nil }
        let modified = { (item: [String: Any]) in item[kSecAttrModificationDate as String] as? Date ?? .distantPast }
        return items
            .filter { (($0[kSecAttrService as String] as? String) ?? "").isEmpty }
            .sorted { modified($0) > modified($1) }
            .compactMap { $0[kSecValuePersistentRef as String] as? Data }
    }
}

nonisolated protocol KeychainStore: AnyObject, Sendable {
    func object(forKey key: String) throws -> Data
    func setObject(_ object: Data, forKey key: String) throws
    func removeObject(forKey key: String) throws
    func removeAllObjects() throws
}

nonisolated extension Valet: KeychainStore {}
