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

    /// Replaces ``shared`` in a test. A simulator never locks, so a test of
    /// the locked launch swaps in a store it can lock. A task local, so the
    /// swap reaches only the test that makes it, not the suites running
    /// beside it. Nothing else sets it.
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
        AppConstants.KeychainKeys.pushDeviceId,
        DebugEndpointStore.keychainKey,
    ]

    /// Home of ``readableWhileLockedKeys``. `.afterFirstUnlockThisDeviceOnly`
    /// is readable once the phone has been unlocked after a restart, and
    /// like ``shared`` never leaves the device.
    private static let readableWhileLocked = Valet.valet(
        with: Identifier(nonEmpty: "org.ntust.app.TigerDuck")!,
        accessibility: .afterFirstUnlockThisDeviceOnly
    )

    /// The valet `key` is written to.
    private static func home(forKey key: String) -> any KeychainStore {
        readableWhileLockedKeys.contains(key) ? readableWhileLocked : shared
    }

    /// Legacy per-app valet at the looser `.afterFirstUnlock` class. We
    /// only read from this so existing installs migrate forward into
    /// ``shared`` instead of appearing logged-out after the accessibility
    /// tightening. Never written to.
    private static let legacyShared = Valet.valet(
        with: Identifier(nonEmpty: "org.ntust.app.TigerDuck")!,
        accessibility: .afterFirstUnlock
    )

    /// Legacy shared-group valet. Older builds mirrored every secret —
    /// including the NTUST password — into the App Group so any extension
    /// (or future MDM-managed group reader) could fish them out. The LA
    /// extension never actually needed credentials, so writes were pure
    /// attack surface. Kept here only to migrate-and-purge existing
    /// installs; never written to.
    private static let legacySharedGroup = Valet.sharedGroupValet(
        with: SharedGroupIdentifier(
            groupPrefix: "group",
            nonEmptyGroup: "org.ntust.app.TigerDuck"
        )!,
        accessibility: .afterFirstUnlock
    )

    static func save(_ data: Data, forKey key: String) throws {
        let home = home(forKey: key)
        // Only while home is empty: once it has a value, `load` never reads ``shared`` for this
        // key. Checking anyway could only refuse saves, losing a refresh token rotated behind a
        // locked screen if the phone reports even an absent item as unreadable.
        if home !== shared, (try? home.object(forKey: key)) == nil {
            try requireNoUnreadableCopyInShared(forKey: key)
        }
        try home.setObject(data, forKey: key)
        // Best-effort: strip stale copies so this write is the single source of truth. An
        // earlier build may have left one in the legacy or shared-group valet, at a looser
        // class, or in ``shared`` for a key whose home is ``readableWhileLocked``.
        for store in [shared, legacyShared, legacySharedGroup] where store !== home {
            try? store.removeObject(forKey: key)
        }
    }

    /// Throws when ``shared`` holds a copy of `key` this launch cannot read.
    ///
    /// That is an earlier build's value on a locked phone, not yet moved by a read after an
    /// unlock. `load` could not see it, so the caller writes a stand-in in its place
    /// (`PushIdentity` mints a fresh device id). ``readableWhileLocked`` takes writes behind a
    /// locked screen and `load` reads it first, so the stand-in would replace the real value
    /// for good. It is refused instead, as a write to ``shared`` behind a locked screen always
    /// is; the real value moves on the next unlocked read.
    private static func requireNoUnreadableCopyInShared(forKey key: String) throws {
        do {
            _ = try shared.object(forKey: key)
        } catch KeychainError.itemNotFound {
            return
        }
    }

    /// ``load(key:)``, but a throw where it answers nil because the Keychain cannot be read now,
    /// as before the first unlock after a restart, rather than because nothing is stored. An
    /// earlier build's copy in ``shared``, which a locked launch cannot read or move, counts too.
    static func loadIfReadable(key: String) throws -> Data? {
        if let value = load(key: key) { return value }
        let home = home(forKey: key)
        if home !== shared { try requireNoUnreadableCopyInShared(forKey: key) }
        do {
            return try home.object(forKey: key)
        } catch KeychainError.itemNotFound {
            return nil
        }
    }

    static func load(key: String) -> Data? {
        let home = home(forKey: key)
        if let value = try? home.object(forKey: key) {
            return value
        }

        // Earlier builds kept these keys in ``shared``, which cannot be read behind a locked
        // screen, so the value moves on the first read after an unlock. The delete waits for
        // the write, for the reason given below.
        if home !== shared, let value = try? shared.object(forKey: key) {
            if (try? home.setObject(value, forKey: key)) != nil {
                try? shared.removeObject(forKey: key)
            }
            return value
        }

        // Migrate from the legacy `.afterFirstUnlock` valet, deleting only once the write
        // lands: the legacy valet is readable behind a locked screen and `shared` cannot be
        // written there, so an unconditional delete would destroy the only copy.
        if let value = try? legacyShared.object(forKey: key) {
            if (try? home.setObject(value, forKey: key)) != nil {
                try? legacyShared.removeObject(forKey: key)
            }
            return value
        }

        // Migrate from the App Group valet (we no longer mirror writes
        // there) and purge the shared copy. Same conditional delete, same
        // reason.
        if let value = try? legacySharedGroup.object(forKey: key) {
            if (try? home.setObject(value, forKey: key)) != nil {
                try? legacySharedGroup.removeObject(forKey: key)
            }
            return value
        }

        guard let legacy = legacyLoad(key: key) else {
            return nil
        }

        if (try? home.setObject(legacy.value, forKey: key)) != nil {
            deleteLegacyItem(legacy.item)
        }
        return legacy.value
    }

    static func delete(key: String) {
        try? readableWhileLocked.removeObject(forKey: key)
        try? shared.removeObject(forKey: key)
        try? legacyShared.removeObject(forKey: key)
        try? legacySharedGroup.removeObject(forKey: key)
        legacyDelete(key: key)
    }

    /// Like `delete(key:)` but returns false if any backing store reported
    /// a failure other than "item not found". Used by the fresh-install
    /// purge to avoid flipping the "installed" flag on partial cleanup.
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
        legacyDelete(key: key)
        return ok
    }

    /// Wipes every secret this app holds, across the current valets and both legacy ones,
    /// keeping only the keys named in `preserving`.
    ///
    /// Backs the erase-everything action. Enumerating `AppConstants.KeychainKeys` instead would
    /// miss whatever key is added next, and a leftover credential makes a "fresh install" not
    /// one. `preserving` is for device configuration that is not user data: the API endpoint
    /// override is kept in the Keychain rather than `UserDefaults` so it outlives a wipe.
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

    /// The item a build before v1.3 wrote for `key`, with the reference that deletes just that one.
    private static func legacyLoad(key: String) -> (value: Data, item: Data)? {
        for item in legacyItems(key: key) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecValuePersistentRef as String: item,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let value = result as? Data {
                return (value, item)
            }
        }
        return nil
    }

    private static func legacyDelete(key: String) {
        legacyItems(key: key).forEach(deleteLegacyItem)
    }

    private static func deleteLegacyItem(_ item: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: item,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// References to the items builds before v1.3 wrote for `key`: generic passwords with the key
    /// as their account and no service. Every valet's items carry the account too, but name a
    /// service, so a match on the account alone would also take the copy `load` has just moved.
    private static func legacyItems(key: String) -> [Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard ((item[kSecAttrService as String] as? String) ?? "").isEmpty else { return nil }
            return item[kSecValuePersistentRef as String] as? Data
        }
    }
}

/// The part of ``Valet`` that ``SecureStore`` uses, so a test can swap its
/// own store in for one of the valets.
nonisolated protocol KeychainStore: AnyObject, Sendable {
    func object(forKey key: String) throws -> Data
    func setObject(_ object: Data, forKey key: String) throws
    func removeObject(forKey key: String) throws
    func removeAllObjects() throws
}

nonisolated extension Valet: KeychainStore {}
