import Defaults
import Foundation

/// One-time migration: silently obtain a Moodle webservice token for users
/// who had NTUST credentials stored before this feature was introduced.
///
/// Idempotent: sets `Defaults[.moodleTokenMigrationDone] = true` on success
/// or when no migration is needed. Does NOT set the flag on failure so the
/// next app launch will retry.
enum MoodleTokenMigration {
    static func runIfNeeded() async {
        guard !Defaults[.moodleTokenMigrationDone] else { return }

        // KeychainManager.loadString is internally synchronous; call it
        // directly off-main so cold launch is not blocked on Keychain I/O.
        let credentials: (String?, String?) = (
            KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId),
            KeychainManager.loadString(key: AppConstants.KeychainKeys.password)
        )

        // No credentials stored → new user or already logged out; mark done to skip future checks.
        guard credentials.0 != nil, credentials.1 != nil else {
            Defaults[.moodleTokenMigrationDone] = true
            return
        }

        // Token already present → already migrated via another path.
        if await MoodleTokenService.shared.currentToken() != nil {
            Defaults[.moodleTokenMigrationDone] = true
            return
        }

        do {
            _ = try await MoodleTokenService.shared.refreshTokenIfNeeded()
            Defaults[.moodleTokenMigrationDone] = true
        } catch {
            // Do not set flag; next launch will retry. Surface to Sentry
            // so we can see how often this silently retries in the wild.
            AppLogger.captureError(error, context: ["migration": "moodleToken"])
        }
    }
}
