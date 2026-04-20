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

        let credentials = await MainActor.run {
            (
                KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId),
                KeychainManager.loadString(key: AppConstants.KeychainKeys.password)
            )
        }

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
            // Silent failure — do not set flag; next launch will retry.
        }
    }
}
