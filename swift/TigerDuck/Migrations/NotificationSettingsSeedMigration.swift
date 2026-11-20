import Foundation

enum NotificationSettingsSeedMigration {
    private static let doneKey = "NotificationSettingsSeedMigration.v1.done"

    static func runIfNeeded(
        reconcile: (_ onSettled: @escaping @MainActor () -> Void) -> Void
    ) {
        guard !AppUserDefaults.standard.bool(forKey: doneKey) else { return }
        reconcile {
            AppUserDefaults.standard.set(true, forKey: doneKey)
        }
    }
}
