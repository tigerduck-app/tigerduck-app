#if os(iOS)
import Foundation

nonisolated struct MailInboxCursor: Sendable {
    let prefs: any MailPreferences

    func reset(to status: MailboxStatusInfo) {
        prefs.inboxUIDValidity = status.uidValidity
        prefs.inboxNextUID = status.uidNext
    }

    func marker(for status: MailboxStatusInfo) -> UInt32? {
        guard prefs.inboxUIDValidity == status.uidValidity else { return nil }
        return prefs.inboxNextUID
    }

    func noteSeen(_ status: MailboxStatusInfo) {
        if prefs.inboxUIDValidity != status.uidValidity || prefs.inboxNextUID == nil {
            reset(to: status)
        } else if let marker = prefs.inboxNextUID, status.uidNext > marker {
            prefs.inboxNextUID = status.uidNext
        }
    }

    func passedOver(uidValidity: UInt32) -> Set<UInt32> {
        prefs.inboxMutedUIDs.flatMap { $0.uidValidity == uidValidity ? $0.uids : nil } ?? []
    }

    func advance(to next: UInt32, uidValidity: UInt32, passedOver: Set<UInt32>) {
        guard prefs.inboxUIDValidity == uidValidity else { return }
        let marker = max(next, prefs.inboxNextUID ?? 0)
        prefs.inboxNextUID = marker
        let held = passedOver.filter { $0 >= marker }
        prefs.inboxMutedUIDs = held.isEmpty ? nil : MailMutedUIDs(uidValidity: uidValidity, uids: held)
    }
}
#endif
