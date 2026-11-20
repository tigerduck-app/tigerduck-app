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

nonisolated struct MailNotifier: Sendable {
    static let summaryIdentifier = "school-mail-summary"
    static let authFailureIdentifier = "school-mail-auth-failed"

    let center: any MailNotificationCenter

    static func identifier(uidValidity: UInt32, uid: UInt32) -> String {
        "school-mail-\(uidValidity)-\(uid)"
    }

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
