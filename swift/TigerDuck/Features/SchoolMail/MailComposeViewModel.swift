#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class MailComposeViewModel {
    nonisolated struct Attachment: Identifiable, Equatable, Sendable {
        let id = UUID()
        var filename: String
        var mimeType: String
        var data: Data
    }

    private(set) var draft = MailComposeDraft()
    private(set) var status = MailComposeStatus()
    @ObservationIgnored private var tracking = MailComposeTracking()
    @ObservationIgnored let events: MailboxEvents
    @ObservationIgnored private let context: MailComposeContext
    @ObservationIgnored private let session: MailPageSession
    @ObservationIgnored private let sender: MailAddress
    @ObservationIgnored private var folderRoles: [MailFolderRole: String]
    @ObservationIgnored private let services: MailComposeServices

    init(
        context: MailComposeContext,
        session: MailPageSession,
        sender: MailAddress,
        folderRoles: [MailFolderRole: String],
        events: MailboxEvents? = nil,
        prefs: (any MailPreferences)? = nil,
        cache: MailCache? = nil,
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.context = context
        self.session = session
        self.sender = sender
        self.folderRoles = folderRoles
        self.events = events ?? MailboxEvents()
        services = MailComposeServices(prefs: prefs ?? MailAccountManager.shared.prefs,
                                       cache: cache ?? MailAccountManager.shared.cache, sleep: sleep, now: now)
    }

    var to: String {
        get { draft.to }
        set { draft.to = newValue; tracking.edited.insert(.to) }
    }
    var cc: String {
        get { draft.cc }
        set { draft.cc = newValue; tracking.edited.insert(.cc) }
    }
    var bcc: String { get { draft.bcc } set { draft.bcc = newValue } }
    var subject: String {
        get { draft.subject }
        set { draft.subject = newValue; tracking.edited.insert(.subject) }
    }
    var body: String {
        get { draft.body }
        set { draft.body = newValue; tracking.edited.insert(.body) }
    }
    var showCcBcc: Bool { get { draft.showCcBcc } set { draft.showCcBcc = newValue } }
    var attachments: [Attachment] { draft.attachments }
    var isSending: Bool { status.isSending }
    var isLoading: Bool { status.isLoading }
    var error: String? { status.error }
    var errorNeedsAcknowledging: Bool { status.errorNeedsAcknowledging }
    var loadError: String? { status.loadError }
    var invalidRecipients: [String] { status.invalidRecipients }
    var didFinish: Bool { status.didFinish }
    var sentCopy: SentCopy? { status.sentCopy }

    var hasChanges: Bool { draft.snapshot != tracking.baseline }

    func prepare() async {
        guard !tracking.prepareStarted else { return }
        tracking.prepareStarted = true
        await runPrepare()
    }

    func retryPrepare() async {
        guard !isLoading, !isSending else { return }
        await runPrepare()
    }

    /// A prefill fills only the fields the user has not typed into while it loaded.
    private func runPrepare() async {
        if !tracking.edited.contains(.to) { draft.to = MailRecipients.format(context.to) }
        guard context.mode != .new else {
            tracking.baseline = draft.snapshot
            return
        }
        status.isLoading = true
        status.loadError = nil
        defer { status.isLoading = false }
        do {
            switch try await MailComposePrefill.fetch(context, sender: sender, session: session, cache: services.cache) {
            case .prefill(let prefill):
                apply(prefill)
            case .missingDraft:
                status.loadError = String(localized: "school_mail_error_generic")
                tracking.baseline = draft.snapshot
            case .nothing:
                tracking.baseline = draft.snapshot
            }
        } catch {
            status.loadError = MailAccountManager.LoginError(error).message
            tracking.baseline = MailComposeDraft().snapshot
        }
    }

    private func apply(_ prefill: MailComposePrefill) {
        let edited = tracking.edited
        if let to = prefill.to, !edited.contains(.to) { draft.to = to }
        if let cc = prefill.cc, !edited.contains(.cc) { draft.cc = cc }
        if !edited.contains(.subject) { draft.subject = prefill.subject }
        if !edited.contains(.body) { draft.body = prefill.body }
        draft.showCcBcc = draft.showCcBcc || prefill.showCcBcc
        let existingIDs = Set(attachments.map(\.id))
        draft.attachments += prefill.attachments.filter { !existingIDs.contains($0.id) }
        tracking.baseline = MailComposeDraft.snapshot(
            to: prefill.to ?? "", cc: prefill.cc ?? "", bcc: "", subject: prefill.subject, body: prefill.body,
            attachmentIDs: prefill.attachments.map(\.id))
        if let draft = prefill.draft {
            tracking.draftPageUIDValidity = draft.pageUIDValidity
            tracking.draftWasAlreadyDeleted = draft.wasAlreadyDeleted
        }
        tracking.sourceLoaded = true
    }

    func addAttachment(filename: String, mimeType: String, data: Data) {
        guard !isSending else { return }
        draft.attachments.append(Attachment(filename: filename, mimeType: mimeType, data: data))
        status.error = nil
    }

    func removeAttachment(_ id: Attachment.ID) {
        guard !isSending else { return }
        draft.attachments.removeAll { $0.id == id }
    }

    func attachmentReadFailed() { status.error = String(localized: "school_mail_too_large") }
    func acknowledgeError() { status.errorNeedsAcknowledging = false }

    /// A password the server rejected is never sent again: repeated failures lock the school
    /// account and its Wi-Fi, and SMTP `AUTH LOGIN` and the Drafts APPEND each log in afresh.
    private func checkAccount(_ message: String) -> Bool {
        guard services.prefs.authFailed else { return true }
        status.error = message
        return false
    }

    private func validate() -> MailRecipients.Parsed? {
        let credentials = String(localized: "school_mail_send_failed") + "\n" + MailAccountManager.LoginError.credentials.message
        guard checkAccount(credentials), let recipients = status.takeRecipients(of: draft, requireOne: true),
              status.fitsSizeLimit(draft) else { return nil }
        return recipients
    }

    func confirmationIsWarranted() -> Bool {
        guard !isSending else { return false }
        return validate() != nil
    }

    func send() async {
        guard !isSending, let recipients = validate() else { return }
        let isReply = context.mode == .reply || context.mode == .replyAll
        let threading = isReply ? context.original.map(MailReplyComposer.threadingHeaders(for:)) : nil
        let mail = outgoing(recipients, threading: threading)
        let messageID = MailMessageBuilder.makeMessageID()
        var replaced: (folder: String, draft: MailComposeSending.ReplacedDraft)?
        if tracking.sourceLoaded, context.mode == .draft, let message = context.message {
            replaced = (message.folder, replacedDraft(message.uid))
        }
        guard let message = await build(mail, messageID: messageID) else { return }
        defer { status.isSending = false }
        do {
            let filing = try await MailComposeSending.send(MailComposeSending.Send(
                message: message, messageID: messageID, from: sender.address, recipients: mail.envelopeRecipients,
                roles: folderRoles, answered: tracking.sourceLoaded && isReply ? context.message : nil, replaced: replaced
            ), session: session, services: services)
            if let refreshedRoles = filing.roles { adoptFolderRoles(refreshedRoles) }
            if filing.rejectedPassword { session.reportAuthenticationRejection() }
            status.sentCopy = filing.outcome
            if let notice = MailComposeSending.notice(for: filing.outcome) { events.post(.sentCopyNotice(notice)) }
            status.didFinish = true
        } catch MailClientError.sendUnconfirmed {
            status.error = String(localized: "school_mail_send_unconfirmed")
        } catch {
            status.error = String(localized: "school_mail_send_failed") + "\n" + MailAccountManager.LoginError(error).message
        }
    }

    @discardableResult
    func saveDraft() async -> Bool {
        guard !isSending, checkAccount(MailAccountManager.LoginError.credentials.message),
              let recipients = status.takeRecipients(of: draft, requireOne: false) else { return false }
        let mail = outgoing(recipients, threading: nil)
        let savedBaseline = draft.snapshot
        guard status.fitsSizeLimit(draft) else { return false }
        let replacesDraft = tracking.sourceLoaded && context.mode == .draft && context.folder == folderRoles[.drafts]
        let replaced = replacesDraft ? context.uid.map(replacedDraft) : nil
        guard let message = await build(mail, messageID: MailMessageBuilder.makeMessageID()) else { return false }
        defer { status.isSending = false }
        do {
            let refreshedRoles = try await MailComposeSending.saveDraft(message, roles: folderRoles, replacing: replaced,
                                                                        session: session, prefs: services.prefs)
            adoptFolderRoles(refreshedRoles)
            tracking.baseline = savedBaseline
            return true
        } catch is MailFolderUnavailable {
            status.error = String(localized: "school_mail_error_generic")
            return false
        } catch {
            status.error = MailAccountManager.LoginError(error).message
            return false
        }
    }

    /// Marks the sheet as sending and builds the message off the main actor; nil, with sending
    /// ended, when it comes out over the size limit.
    private func build(_ mail: OutgoingMail, messageID: String) async -> Data? {
        let date = services.now()
        status.isSending = true
        let message = await Task.detached { MailMessageBuilder.build(mail, messageID: messageID, date: date) }.value
        guard message.count <= MailConstants.maxEncodedMessageBytes else {
            status.error = String(localized: "school_mail_too_large")
            status.isSending = false
            return nil
        }
        return message
    }

    private func replacedDraft(_ uid: UInt32) -> MailComposeSending.ReplacedDraft {
        MailComposeSending.ReplacedDraft(uid: uid, pageUIDValidity: tracking.draftPageUIDValidity,
                                         wasAlreadyDeleted: tracking.draftWasAlreadyDeleted)
    }

    private func adoptFolderRoles(_ roles: [MailFolderRole: String]) {
        guard roles != folderRoles else { return }
        folderRoles = roles
        events.post(.folderRoles(roles))
    }

    private func outgoing(_ recipients: MailRecipients.Parsed, threading: (inReplyTo: String?, references: [String])?) -> OutgoingMail {
        OutgoingMail(
            from: sender, to: recipients.to, cc: recipients.cc, bcc: recipients.bcc, subject: subject, body: body,
            inReplyTo: threading?.inReplyTo, references: threading?.references ?? [],
            attachments: attachments.map { OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
        )
    }
}
#endif
