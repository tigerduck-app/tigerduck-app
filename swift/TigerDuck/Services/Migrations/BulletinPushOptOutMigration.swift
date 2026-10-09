import Defaults
import Foundation

/// One-shot migration for the 2.0.x `pushServerEnabled` flag, which switched the whole push
/// stack; from 2.1.0 bulletin push is a device-level opt-out of its own. A 2.0.x `false` meant
/// bulletins off (the bulletin page's "Turn off bulletin push" button) or all server push off
/// (the removed "Server push" toggle); both called `disablePushServer()`. Unable to tell which,
/// this turns bulletins off, all that button now does, and also keeps operator pushes off.
/// Reminders, Live Activities and sync triggers are not kept off for either. Nothing else gates
/// on the flag; writing `true` records the run and comes last, as this branches on it: a run
/// that dies part-way leaves `false` and re-applies whole at the next launch.
enum BulletinPushOptOutMigration {
    private static let doneKey = "BulletinPushOptOutMigration.v1.done"

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }
        guard Defaults[.pushServerEnabled] == false else { return }
        Defaults[.bulletinPushEnabled] = false
        // A 2.0.x `false` may have meant all server push off: re-enabling operator pushes then
        // is a consent problem, while keeping them off costs a bulletins-only user one tap on
        // the TigerSync page. Only ever set `true`, so an earlier opt-out survives.
        Defaults[.serverPushUserOptOut] = true
        // Last, and last for a reason — see the type doc.
        Defaults[.pushServerEnabled] = true
    }
}
