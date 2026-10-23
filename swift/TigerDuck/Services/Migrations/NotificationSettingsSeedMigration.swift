import Foundation

enum NotificationSettingsSeedMigration {
    private static let doneKey = "NotificationSettingsSeedMigration.v1.done"

    static func runIfNeeded(
        reconcile: (_ onSettled: @escaping @MainActor () -> Void) -> Void
    ) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        reconcile {
            UserDefaults.standard.set(true, forKey: doneKey)
        }
    }
}
