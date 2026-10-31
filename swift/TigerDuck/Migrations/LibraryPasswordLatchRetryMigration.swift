import Foundation

enum LibraryPasswordLatchRetryMigration {
    private static let doneKey = "LibraryPasswordLatchRetryMigration.v1.done"
    private static let latchKey = "libraryStoredPasswordRejected"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard defaults.bool(forKey: latchKey) else { return }
        defaults.removeObject(forKey: latchKey)
        LibraryService.storedPasswordRefusals = (StoredPasswordBackoff.quickRetries.count, .distantPast)
    }
}
