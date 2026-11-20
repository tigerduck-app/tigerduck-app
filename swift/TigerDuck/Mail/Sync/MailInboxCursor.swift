#if os(iOS)
import Foundation

nonisolated struct MailInboxCursor: Sendable {
    let prefs: any MailPreferences

    func reset(to status: MailboxStatusInfo, for signIn: SignIn) {
        prefs.change(for: signIn) {
            $0.inboxUIDValidity = status.uidValidity
            $0.inboxNextUID = status.uidNext
        }
    }

    func marker(for status: MailboxStatusInfo) -> UInt32? {
        guard prefs.inboxUIDValidity == status.uidValidity else { return nil }
        return prefs.inboxNextUID
    }

    func noteSeen(_ status: MailboxStatusInfo, for signIn: SignIn) {
        if prefs.inboxUIDValidity != status.uidValidity || prefs.inboxNextUID == nil {
            reset(to: status, for: signIn)
        } else if let marker = prefs.inboxNextUID, status.uidNext > marker {
            prefs.change(for: signIn) { $0.inboxNextUID = status.uidNext }
        }
    }

    func passedOver(uidValidity: UInt32) -> Set<UInt32> {
        prefs.inboxMutedUIDs.flatMap { $0.uidValidity == uidValidity ? $0.uids : nil } ?? []
    }

    static func toPassOver(
        _ unread: [MailSummary], passedOver: Set<UInt32>, mutes: (MailSummary) -> Bool
    ) -> Set<UInt32> {
        Set(unread.filter { passedOver.contains($0.uid) || mutes($0) }.map(\.uid))
    }

    func advance(to next: UInt32, uidValidity: UInt32, passedOver: Set<UInt32>, for signIn: SignIn) {
        guard prefs.inboxUIDValidity == uidValidity else { return }
        let marker = max(next, prefs.inboxNextUID ?? 0)
        let held = passedOver.filter { $0 >= marker }
        prefs.change(for: signIn) {
            $0.inboxNextUID = marker
            $0.inboxMutedUIDs = held.isEmpty ? nil : MailMutedUIDs(uidValidity: uidValidity, uids: held)
        }
    }
}
#endif
