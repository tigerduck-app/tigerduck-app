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

/// New-mail notifications (design doc §8.6): title = sender, body = subject, both as
/// cleaned plain text; more than five at once collapse into one.
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

    /// Returns the UIDs whose notification the system refused *and might yet accept*. The caller
    /// holds its seen-UID marker at the lowest of them: §8.5's contract is notify, *then*
    /// advance, and a refused `add` is as much a failure to notify as a process death is —
    /// swallowing it while the marker moves on means that mail is never notified and never
    /// reconsidered by any trigger. (`add` with `trigger: nil` throws on invalid content and
    /// when the notification service is unavailable; it is not a never-happens path.)
    ///
    /// A refusal that will be made again for the same reason is left out of the set. Holding the
    /// marker for one of those never delivers the notification and never stops trying: the mail
    /// is re-fetched and re-reported as new on every poll for as long as the student leaves
    /// notification permission off, and every mail behind it waits in the same queue. Reporting
    /// it once and moving on is the lesser loss, and the mail itself is still in the list.
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
                title: sender,
                body: subject,
                userInfo: ["kind": MailConstants.notificationKind, "folder": MailConstants.inbox, "uid": Int(message.uid)]
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
