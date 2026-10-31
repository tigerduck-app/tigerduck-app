import Defaults
import Foundation

/// On iOS, Keychain items survive a reinstall. They are deleted before `AuthTokenManager` is
/// built: its init caches the v3 tokens, which it would write back on the next refresh, letting a
/// different user sync the previous user's cloud data.
@MainActor
enum FreshInstallKeychainPurge {
    private static var keys: [String] {
        [
            AppConstants.KeychainKeys.studentId,
            AppConstants.KeychainKeys.password,
            AppConstants.KeychainKeys.libraryUsername,
            AppConstants.KeychainKeys.libraryPassword,
            AppConstants.KeychainKeys.libraryToken,
            AppConstants.KeychainKeys.libraryTokenExpiry,
            AppConstants.KeychainKeys.moodleToken,
            AppConstants.KeychainKeys.moodlePrivateToken,
            AuthTokenManager.accessTokenKey,
            AuthTokenManager.refreshTokenKey,
            AuthTokenManager.expiresAtKey,
            AuthTokenManager.refreshTokenUsesKey,
            AuthTokenManager.departingSessionKey,
        ]
    }

    /// Whether this launch is a fresh install. The install marker is set only once every item is
    /// gone, so a failed delete is tried again on the next launch.
    static func runIfFreshInstall() -> Bool {
        guard !Defaults[.appHasBeenInstalled] else { return false }
        let allOk = keys
            .map { KeychainManager.deleteReportingSuccess(key: $0) }
            .allSatisfy { $0 }
        if allOk {
            Defaults[.appHasBeenInstalled] = true
        }
        return true
    }
}
