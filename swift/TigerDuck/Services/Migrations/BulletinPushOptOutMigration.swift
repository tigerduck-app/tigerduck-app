import Defaults
import Foundation

/// One-shot migration: disambiguates the 2.0.x `pushServerEnabled` flag on
/// upgrade to 2.1.0, now that bulletin push is a separate, device-level
/// opt-out (spec §6 item 5) instead of a switch for the whole push stack.
///
/// A `false` value written by the shipped 2.0.x app meant either "the user
/// turned bulletins off" (the bulletin page's 關閉公告推播 button) or "the
/// user turned off all server push" (the since-removed 「伺服器推播」
/// settings-menu toggle) — both called the same `disablePushServer()`. This
/// migration cannot tell which one happened, so it takes the reading that
/// matches what the bulletin page's button does now: mark bulletins off and
/// re-arm the push stack so the device registers again. Assignment
/// reminders, Live Activities and sync triggers were never meant to stay
/// off for either kind of 2.0.x user, and re-registering is always safe —
/// the device row is soft-deleted, not gone, and `POST /devices/register`
/// clears the tombstone unconditionally.
enum BulletinPushOptOutMigration {
    private static let doneKey = "BulletinPushOptOutMigration.v1.done"

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }
        guard Defaults[.pushServerEnabled] == false else { return }
        Defaults[.bulletinPushEnabled] = false
        Defaults[.pushServerEnabled] = true
        // Conservative reading of the same ambiguity: a 2.0.x `false` might
        // have meant "all server push off", not just bulletins, and
        // re-enabling operator pushes (接收額外伺服器推播) for someone who
        // deliberately turned every server push off is a consent problem —
        // unlike turning them back off for someone who only meant
        // bulletins, which costs one visible tap on the TigerSync page.
        // Only ever set to `true` here, never `false`: an earlier explicit
        // choice on this same toggle must survive regardless of what this
        // migration decides about `pushServerEnabled`.
        Defaults[.serverPushUserOptOut] = true
    }
}
