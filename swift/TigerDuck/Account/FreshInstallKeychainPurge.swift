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

    enum Outcome {
        case installedBefore
        case purged
        case itemsLeft

        var isFreshInstall: Bool { self != .installedBefore }
    }

    static func runIfFreshInstall(
        delete: (String) -> Bool = { KeychainManager.deleteReportingSuccess(key: $0) }
    ) -> Outcome {
        guard !Defaults[.appHasBeenInstalled] else { return .installedBefore }
        let everyItemDeleted = keys.map(delete).allSatisfy { $0 }
        guard everyItemDeleted else { return .itemsLeft }
        Defaults[.appHasBeenInstalled] = true
        return .purged
    }
}
