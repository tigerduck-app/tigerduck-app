import Defaults
import Foundation

enum SyncedAccountSeedMigration {
    private static let doneKey = "SyncedAccountSeedMigration.v1.done"

    static func runIfNeeded(signedIn: Bool) {
        guard !AppUserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { AppUserDefaults.standard.set(true, forKey: doneKey) }
        guard signedIn else {
            AppState.forgetSyncProgress()
            return
        }
        Defaults[.categoriesSyncedOnce].formUnion(AppState.reenableCategories)
    }
}
