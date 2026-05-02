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
    private static let shared = Valet.valet(
        with: Identifier(nonEmpty: "org.ntust.app.TigerDuck")!,
        accessibility: .whenUnlockedThisDeviceOnly
    )

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
        try shared.setObject(data, forKey: key)
        // Best-effort cleanup: a previous build may still have the value
        // sitting in the legacy / shared-group valets at a looser
        // accessibility class. Strip any stale copies so the new write
        // is the single source of truth.
        try? legacyShared.removeObject(forKey: key)
        try? legacySharedGroup.removeObject(forKey: key)
    }

    static func load(key: String) -> Data? {
        if let value = try? shared.object(forKey: key) {
            return value
        }

        // Migrate from the previous `.afterFirstUnlock` per-app valet.
        if let value = try? legacyShared.object(forKey: key) {
            try? shared.setObject(value, forKey: key)
            try? legacyShared.removeObject(forKey: key)
            return value
        }

        // Migrate from the App Group valet (we no longer mirror writes
        // there) and purge the shared copy.
        if let value = try? legacySharedGroup.object(forKey: key) {
            try? shared.setObject(value, forKey: key)
            try? legacySharedGroup.removeObject(forKey: key)
            return value
        }

        guard let legacyValue = legacyLoad(key: key) else {
            return nil
        }

        let migrated = (try? shared.setObject(legacyValue, forKey: key)) != nil
        if migrated {
            legacyDelete(key: key)
        }
        return legacyValue
    }

    static func delete(key: String) {
        try? shared.removeObject(forKey: key)
        try? legacyShared.removeObject(forKey: key)
        try? legacySharedGroup.removeObject(forKey: key)
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
