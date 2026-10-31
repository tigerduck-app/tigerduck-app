import Foundation

enum StoredPasswordLatchRetryMigration {
    private static let doneKey = "StoredPasswordLatchRetryMigration.v1.done"
    private static let latchKey = "ntustStoredPasswordRejected"

    static func runIfNeeded() {
        let defaults = AppUserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard defaults.bool(forKey: latchKey) else { return }
        defaults.removeObject(forKey: latchKey)
        SSOLoginService.storedPasswordRefusals = (StoredPasswordBackoff.quickRetries.count, .distantPast)
    }
}
