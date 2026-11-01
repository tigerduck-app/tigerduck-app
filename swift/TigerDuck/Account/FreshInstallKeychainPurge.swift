import Defaults
import Foundation

/// On iOS, Keychain items survive a reinstall.
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
