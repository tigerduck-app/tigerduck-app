import Defaults
import Foundation

/// One-shot migration: keeps the re-enable check for an install signed in at the update. A
/// category switched back on is checked only once this device holds the account's data
/// (`AppState.hasSyncedAccount`), which 2.3.0 and earlier kept no record of. Without this, turning
/// TigerSync back on there checks nothing, and the first sync takes the server's data over what
/// was edited here while it was off (https://github.com/tigerduck-app/tigerduck-app/issues/402).
/// Keep while a device can still arrive here from 2.3.0 or earlier.
enum SyncedAccountSeedMigration {
    private static let doneKey = "SyncedAccountSeedMigration.v1.done"

    /// `signedIn` is `AuthService.hasStoredCredentials` at launch. A fresh install reads as signed
    /// out, since `AppState.init` clears the keychain before `AuthService` reads it.
    static func runIfNeeded(signedIn: Bool) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }
        guard signedIn else { return }
        Defaults[.accountSyncedOnce] = true
    }
}
