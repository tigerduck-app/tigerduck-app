#if os(iOS)
import Foundation

/// The inbox's new-mail marker: the UIDVALIDITY and the next UID below which every mail was seen or
/// notified, with the muted mail at or above it that a check already passed over. The sign-in, the
/// mail page and the checks move it only through this type.
nonisolated struct MailInboxCursor: Sendable {
    let prefs: any MailPreferences

    /// Starts the marker at the inbox's next UID, as after a sign-in or a recreated inbox.
    func reset(to status: MailboxStatusInfo) {
        prefs.inboxUIDValidity = status.uidValidity
        prefs.inboxNextUID = status.uidNext
    }

    /// The marker for `status`'s inbox; nil when there is none yet or the inbox was recreated.
    func marker(for status: MailboxStatusInfo) -> UInt32? {
        guard prefs.inboxUIDValidity == status.uidValidity else { return nil }
        return prefs.inboxNextUID
    }

    /// The page showed the inbox as `status` has it, so the mail below its next UID was seen.
    func noteSeen(_ status: MailboxStatusInfo) {
        if prefs.inboxUIDValidity != status.uidValidity || prefs.inboxNextUID == nil {
            reset(to: status)
        } else if let marker = prefs.inboxNextUID, status.uidNext > marker {
            prefs.inboxNextUID = status.uidNext
        }
    }

    /// The muted mail of the inbox at `uidValidity` a check passed over.
    func passedOver(uidValidity: UInt32) -> Set<UInt32> {
        prefs.inboxMutedUIDs.flatMap { $0.uidValidity == uidValidity ? $0.uids : nil } ?? []
    }

    /// Moves the marker up to `next`, never down, and keeps the passed-over mail at or above it;
    /// leaves both alone when the inbox was recreated since the check began.
    func advance(to next: UInt32, uidValidity: UInt32, passedOver: Set<UInt32>) {
        guard prefs.inboxUIDValidity == uidValidity else { return }
        let marker = max(next, prefs.inboxNextUID ?? 0)
        prefs.inboxNextUID = marker
        let held = passedOver.filter { $0 >= marker }
        prefs.inboxMutedUIDs = held.isEmpty ? nil : MailMutedUIDs(uidValidity: uidValidity, uids: held)
    }
}
#endif
