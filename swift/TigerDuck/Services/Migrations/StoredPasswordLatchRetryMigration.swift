import Foundation

/// One-shot migration: 2.6.2 and earlier stopped every automatic post of the stored password after
/// one refusal until the user signed in again, so a device whose backend session was revoked
/// stayed signed out of TigerSync (https://github.com/tigerduck-app/tigerduck-app/issues/768).
/// A device that held that latch takes up `SSOLoginService.storedPasswordRefusals` with its quick
/// retries spent: one try goes at once, then one every six hours. Keep while a device can still
/// update from 2.6.2 or earlier.
enum StoredPasswordLatchRetryMigration {
    private static let doneKey = "StoredPasswordLatchRetryMigration.v1.done"
    private static let latchKey = "ntustStoredPasswordRejected"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard defaults.bool(forKey: latchKey) else { return }
        defaults.removeObject(forKey: latchKey)
        SSOLoginService.storedPasswordRefusals = (SSOLoginService.storedPasswordQuickRetries.count, .distantPast)
    }
}
