import Foundation

/// Anonymous, Keychain-backed identity for the push server.
///
/// * `userId` — stable UUIDv4 per user. Survives app re-install because
///   iOS Keychain persists across uninstall. `AppState`'s fresh-install
///   sweep explicitly deletes it so a fresh install rotates.
/// * `deviceId` — stable UUIDv4 per install. A reinstall gets a new id.
///
/// No real student ID is sent to the push server — the backend only needs
/// a stable opaque handle to fan-out pushes.
nonisolated struct PushIdentity: Sendable {
    let userId: String
    let deviceId: String

    /// Load existing ids or mint new ones. Write-through on first mint.
    static func loadOrCreate() -> PushIdentity {
        let userId = loadOrMint(key: AppConstants.KeychainKeys.pushUserId)
        let deviceId = loadOrMint(key: AppConstants.KeychainKeys.pushDeviceId)
        return PushIdentity(userId: userId, deviceId: deviceId)
    }

    private static func loadOrMint(key: String) -> String {
        if let existing = KeychainManager.loadString(key: key), !existing.isEmpty {
            return existing
        }
        // Lowercase so server-side casing is normalised at the source — the
        // push server treats the id as opaque, but URL paths and database
        // keys built from it are case-sensitive.
        let minted = UUID().uuidString.lowercased()
        KeychainManager.saveString(key: key, value: minted)
        return minted
    }
}
