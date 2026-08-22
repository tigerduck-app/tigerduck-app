import Foundation

/// Persistent device identity for the push server.
///
/// A single UUIDv4 stored in the iOS Keychain. Keychain items survive
/// app uninstall/reinstall, so this UUID is stable across the device's
/// lifetime (until the user resets the device or explicitly wipes
/// Keychain via Settings).
nonisolated struct PushIdentity: Sendable {
    let uuid: String

    static func loadOrCreate() -> PushIdentity {
        if let existing = KeychainManager.loadString(
            key: AppConstants.KeychainKeys.pushDeviceId
        ), !existing.isEmpty {
            return PushIdentity(uuid: existing)
        }
        // Migrate: if the old pushUserId exists, adopt it as the new
        // canonical UUID to avoid orphaning the server-side record.
        if let legacy = KeychainManager.loadString(
            key: "push_user_id"
        ), !legacy.isEmpty {
            KeychainManager.saveString(
                key: AppConstants.KeychainKeys.pushDeviceId,
                value: legacy
            )
            KeychainManager.delete(key: "push_user_id")
            return PushIdentity(uuid: legacy)
        }
        let minted = UUID().uuidString.lowercased()
        KeychainManager.saveString(
            key: AppConstants.KeychainKeys.pushDeviceId,
            value: minted
        )
        return PushIdentity(uuid: minted)
    }
}
