#if os(iOS)
import Foundation
import UserNotifications

nonisolated protocol MailNotificationCenter: Sendable {
    func add(_ request: UNNotificationRequest) async throws
    func removeDelivered(withIdentifiers identifiers: [String])
    func removeAllMailNotifications() async
}

nonisolated struct SystemMailNotificationCenter: MailNotificationCenter {
    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    func removeDelivered(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removeAllMailNotifications() async {
        let center = UNUserNotificationCenter.current()
        let identifiers = await center.deliveredNotifications()
            .filter { $0.request.content.threadIdentifier == MailConstants.notificationThread }
            .map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// New-mail notifications: title = subject, body = sender, both as cleaned plain text; more
/// than five at once collapse into one. Mail stacks in a thread of its own, so the title needs
/// no `Email:` prefix to tell it apart. Subject as the title is a product decision, not a bug,
/// and matches what the Android app produces for the same mail.
nonisolated struct MailNotifier: Sendable {
    static let summaryIdentifier = "school-mail-summary"
    static let authFailureIdentifier = "school-mail-auth-failed"

    let center: any MailNotificationCenter

    static func identifier(uidValidity: UInt32, uid: UInt32) -> String {
        "school-mail-\(uidValidity)-\(uid)"
    }

    /// Whether a refusal from `add` is worth waiting for, which is what decides whether the
    /// caller holds its marker.
    ///
    /// Notification permission being off, and content the system will not accept, are answers
    /// that do not change between one poll and the next: the same `add` refuses the same way
    /// every 60 s. Everything else — an unavailable notification service, a failed XPC hop, an
    /// error this app has never seen — might not refuse next time, so it is treated as
    /// transient and the mail is reconsidered.
    static func isTransient(_ error: any Error) -> Bool {
        let error = error as NSError
        guard error.domain == UNErrorDomain, let code = UNError.Code(rawValue: error.code) else { return true }
        switch code {
        case .notificationsNotAllowed,
             .attachmentInvalidURL, .attachmentUnrecognizedType, .attachmentInvalidFileSize,
             .attachmentNotInDataStore, .attachmentMoveIntoDataStoreFailed, .attachmentCorrupt,
             .notificationInvalidNoDate, .notificationInvalidNoContent,
             .contentProvidingObjectNotAllowed, .contentProvidingInvalid,
             .badgeInputInvalid:
            return false
        @unknown default:
            return true
        }
    }

    /// Returns the UIDs whose notification the system refused but might yet accept. The caller
    /// holds its seen-UID marker at the lowest of them: it notifies, then advances, and a refused
    /// `add` is a failure to notify, so letting the marker pass it loses that mail for good. (`add`
    /// with `trigger: nil` does throw, on invalid content or an unavailable notification service.)
    ///
    /// A refusal that will recur for the same reason is left out. Holding the marker for it would
    /// re-report the mail as new on every poll while permission stays off, and hold up every mail
    /// behind it. Reporting it once is the lesser loss, and the mail is still in the list.
    @discardableResult
    func notify(_ messages: [MailSummary], uidValidity: UInt32) async -> Set<UInt32> {
        guard !messages.isEmpty else { return [] }
        if messages.count > MailConstants.notificationCollapseThreshold {
            let content = Self.content(
                title: String(localized: "school_mail_account_title"),
                body: String(format: String(localized: "school_mail_new_mail_count"), String(messages.count)),
                userInfo: ["kind": MailConstants.notificationKind, "folder": MailConstants.inbox]
            )
            do {
                try await center.add(UNNotificationRequest(identifier: Self.summaryIdentifier, content: content, trigger: nil))
                return []
            } catch {
                // The one collapsed notification stands for every message in the batch, so a
                // refusal loses all of them — but only a refusal worth retrying holds the batch.
                return Self.isTransient(error) ? Set(messages.map(\.uid)) : []
            }
        }
        var failed: Set<UInt32> = []
        for message in messages {
            let sender = message.fromName?.mailNonEmpty ?? message.fromAddress?.mailNonEmpty
                ?? String(localized: "school_mail_no_sender")
            let subject = message.subject?.mailNonEmpty ?? String(localized: "school_mail_no_subject")
            let content = Self.content(
                title: subject,
                body: sender,
                userInfo: ["kind": MailConstants.notificationKind, "folder": MailConstants.inbox, "uid": Int(message.uid),
                           "uidValidity": Int(uidValidity)]
            )
            let identifier = Self.identifier(uidValidity: uidValidity, uid: message.uid)
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            } catch {
                if Self.isTransient(error) { failed.insert(message.uid) }
            }
        }
        return failed
    }

    func notifyAuthFailure() async {
        let content = Self.content(
            title: String(localized: "school_mail_auth_failed_notification_title"),
            body: String(localized: "school_mail_auth_failed_notification_text"),
            userInfo: ["kind": MailConstants.notificationKind]
        )
        try? await center.add(UNNotificationRequest(identifier: Self.authFailureIdentifier, content: content, trigger: nil))
    }

    /// Called when the mail is read inside the app.
    func removeNotification(uidValidity: UInt32, uid: UInt32) {
        center.removeDelivered(withIdentifiers: [Self.identifier(uidValidity: uidValidity, uid: uid)])
    }

    func removeAll() async {
        await center.removeAllMailNotifications()
    }

    private static func content(title: String, body: String, userInfo: [String: Any]) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = MailTextCleaner.clean(title)
        content.body = MailTextCleaner.clean(body)
        content.threadIdentifier = MailConstants.notificationThread
        content.sound = .default
        content.userInfo = userInfo
        return content
    }
}
#endif
