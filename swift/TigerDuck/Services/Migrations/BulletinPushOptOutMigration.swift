import Defaults
import Foundation

enum BulletinPushOptOutMigration {
    private static let doneKey = "BulletinPushOptOutMigration.v1.done"

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }
        guard Defaults[.pushServerEnabled] == false else { return }
        Defaults[.bulletinPushEnabled] = false
        Defaults[.serverPushUserOptOut] = true
        Defaults[.pushServerEnabled] = true
    }
}
