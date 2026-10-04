import Foundation
import Security
import Valet

nonisolated enum SecureStore {
    /// Per-app valet at the strictest accessibility class compatible with
    /// our usage: foreground re-auth, settings reads, library QR refresh
    /// (all happen while the app is active). The Live Activity widget
    /// reads its snapshot via App Group `UserDefaults` (`SharedSnapshotStore`),
    /// not Keychain, so no extension actually needs these secrets.
    ///
    /// `.whenUnlockedThisDeviceOnly`:
    /// * not migrated to a new device via iCloud Keychain restore
    /// * unreadable while the device is locked (background tasks running
    ///   with the screen locked simply won't see credentials — acceptable
    ///   given the threat model)
    ///
    /// Except the few secrets a locked-screen launch needs, which live in
    /// ``readableWhileLocked``.
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
    /// iOS launches the app in the background for a push, and a locked
    /// phone is the usual case: above all a Live Activity push-to-start,
    /// which hands the app the new activity's update token to register so
    /// the server can end the activity when the class does. Registering
    /// reads the backend session, the device id and the endpoint the device
    /// was pointed at. In ``shared`` none of them could be read there, so
    /// that launch took itself for signed out, minted a throwaway device id
    /// and fell back to the default endpoint — the activity was never
    /// registered, and stayed up after class until the app was next opened.
    ///
    /// The NTUST, Moodle and library credentials stay in ``shared``:
    /// nothing that runs in the background needs them.
    private static let readableWhileLockedKeys: Set<String> = [
        AuthTokenManager.accessTokenKey,
        AuthTokenManager.refreshTokenKey,
        AuthTokenManager.expiresAtKey,
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
        if home !== shared {
            try requireNoUnreadableCopyInShared(forKey: key)
        }
        try home.setObject(data, forKey: key)
        // Best-effort cleanup: a previous build may still have the value
        // sitting in another valet — the legacy / shared-group ones at a
        // looser accessibility class, or ``shared`` for a key that has
        // since moved to ``readableWhileLocked``. Strip any stale copies so
        // the new write is the single source of truth.
        for store in [shared, legacyShared, legacySharedGroup] where store !== home {
            try? store.removeObject(forKey: key)
        }
    }

    /// Throws when ``shared`` holds a copy of `key` this launch cannot read.
    ///
    /// That is an earlier build's value on a locked phone, before its first
    /// read after an unlock moved it. `load` could not see it, so the caller
    /// is writing something in its place — `PushIdentity` mints a fresh
    /// device id. ``readableWhileLocked`` takes writes behind a locked
    /// screen and `load` reads it first, so that stand-in would replace the
    /// real value for good. Refused instead, as the write to ``shared``
    /// itself always was there; the real value moves on the next unlocked
    /// read.
    private static func requireNoUnreadableCopyInShared(forKey key: String) throws {
        do {
            _ = try shared.object(forKey: key)
        } catch KeychainError.itemNotFound {
            return
        }
    }

    static func load(key: String) -> Data? {
        let home = home(forKey: key)
        if let value = try? home.object(forKey: key) {
            return value
        }

        // Every build before ``readableWhileLocked`` kept its keys in
        // ``shared``. That cannot be read behind a locked screen, so the
        // value moves on the first read after an unlock. Conditional
        // delete, for the reason given below.
        if home !== shared, let value = try? shared.object(forKey: key) {
            if (try? home.setObject(value, forKey: key)) != nil {
                try? shared.removeObject(forKey: key)
            }
            return value
        }

        // Migrate from the previous `.afterFirstUnlock` per-app valet.
        //
        // The delete is conditional on the write, the way the `legacyLoad`
        // branch below already does it. Unconditionally, this destroys
        // credentials: the legacy valet is `.afterFirstUnlock` and readable
        // behind a locked screen, while `shared` is
        // `.whenUnlockedThisDeviceOnly` and cannot be written there — so a
        // read taken while locked would succeed, fail to copy forward, and
        // then delete the only remaining copy.
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

        guard let legacyValue = legacyLoad(key: key) else {
            return nil
        }

        let migrated = (try? home.setObject(legacyValue, forKey: key)) != nil
        if migrated {
            legacyDelete(key: key)
        }
        return legacyValue
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

    /// Wipe every secret this app holds, across the current valet and both
    /// legacy ones, keeping only the keys named in `preserving`.
    ///
    /// Backs the erase-everything action. Enumerating
    /// `AppConstants.KeychainKeys` instead would quietly miss whatever key
    /// gets added next — and a leftover credential is precisely what makes
    /// a "fresh install" not one.
    ///
    /// `preserving` exists for device configuration that is not user data:
    /// the API endpoint override is stored here specifically so it outlives
    /// a wipe, which is the whole reason it is in the Keychain rather than
    /// `UserDefaults`.
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

/// The part of ``Valet`` that ``SecureStore`` uses, so a test can swap its
/// own store in for one of the valets.
nonisolated protocol KeychainStore: AnyObject, Sendable {
    func object(forKey key: String) throws -> Data
    func setObject(_ object: Data, forKey key: String) throws
    func removeObject(forKey key: String) throws
    func removeAllObjects() throws
}

nonisolated extension Valet: KeychainStore {}
