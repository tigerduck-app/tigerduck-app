#if os(iOS)
import Foundation

nonisolated enum MailComposeMode: Equatable, Sendable {
    case new, reply, replyAll, forward, draft
}

nonisolated struct MailComposeContext: Identifiable, Sendable {
    let id = UUID()
    var mode: MailComposeMode
    var folder: String?
    var uid: UInt32?
    var original: MailOriginal?
    var attachments: [MailBodyPart] = []
    var to: [MailAddress] = []

    var message: (folder: String, uid: UInt32)? {
        guard let folder, let uid else { return nil }
        return (folder, uid)
    }
}

struct MailComposeDraft {
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    var showCcBcc = false
    var attachments: [MailComposeViewModel.Attachment] = []

    var snapshot: String {
        Self.snapshot(to: to, cc: cc, bcc: bcc, subject: subject, body: body, attachmentIDs: attachments.map(\.id))
    }

    static func snapshot(
        to: String, cc: String, bcc: String, subject: String, body: String, attachmentIDs: [UUID]
    ) -> String {
        [to, cc, bcc, subject, body, attachmentIDs.map(\.uuidString).joined()].joined(separator: "\u{1F}")
    }
}

struct MailComposeStatus {
    var isSending = false
    var isLoading = false
    var error: String? {
        didSet { errorNeedsAcknowledging = error != nil }
    }
    var errorNeedsAcknowledging = false
    var loadError: String?
    var invalidRecipients: [String] = []
    var didFinish = false
    var sentCopy: SentCopy?

    mutating func takeRecipients(of draft: MailComposeDraft, requireOne: Bool) -> MailRecipients.Parsed? {
        error = nil
        invalidRecipients = []
        let recipients = MailRecipients.parse(to: draft.to, cc: draft.cc, bcc: draft.bcc)
        if !recipients.invalid.isEmpty {
            invalidRecipients = recipients.invalid
            error = String(format: String(localized: "school_mail_invalid_recipients"), recipients.invalid.joined(separator: ", "))
            return nil
        }
        if requireOne, (recipients.to + recipients.cc + recipients.bcc).isEmpty {
            error = String(localized: "school_mail_no_recipient")
            return nil
        }
        return recipients
    }

    mutating func fitsSizeLimit(_ draft: MailComposeDraft) -> Bool {
        let attachmentBytes = draft.attachments.map(\.data.count)
        guard MailMessageBuilder.estimateEncodedSize(body: draft.body, attachmentByteCounts: attachmentBytes)
                <= MailConstants.maxEncodedMessageBytes else {
            error = String(localized: "school_mail_too_large")
            return false
        }
        return true
    }
}

enum MailComposeField {
    case to, cc, subject, body
}

struct MailComposeTracking {
    var edited: Set<MailComposeField> = []
    var baseline = ""
    var prepareStarted = false
    var sourceLoaded = false
    var draftPageUIDValidity: UInt32?
    var draftWasAlreadyDeleted = false
}

struct MailComposeServices {
    let prefs: any MailPreferences
    let cache: MailCache
    let sleep: (Duration) async -> Void
    let now: () -> Date
}
#endif
