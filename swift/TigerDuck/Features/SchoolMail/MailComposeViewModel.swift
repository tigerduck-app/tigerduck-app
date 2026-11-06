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
    @ObservationIgnored private let signIn: SignIn

    init(
        context: MailComposeContext,
        session: MailPageSession,
        sender: MailAddress,
        folderRoles: [MailFolderRole: String],
        events: MailboxEvents? = nil,
        prefs: (any MailPreferences)? = nil,
        cache: MailCache? = nil,
        sleep: @escaping (Duration) async -> Void = { try? await AppClock.sleep(until: ContinuousClock.now + $0) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.context = context
        self.session = session
        self.sender = sender
        self.folderRoles = folderRoles
        self.events = events ?? MailboxEvents()
        signIn = session.account.currentSignIn
        let cache = cache ?? MailAccountManager.shared.cache
        services = MailComposeServices(prefs: prefs ?? MailAccountManager.shared.prefs, cache: cache, sleep: sleep, now: now, contacts:
            MailComposeContacts(signIn: signIn, own: sender.address, cache: cache, roles: folderRoles, now: now))
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
    var shouldClose: Bool { status.didFinish || status.signInEnded }
    var sentCopy: SentCopy? { status.sentCopy }
    var mode: MailComposeMode { context.mode }
    var contacts: MailComposeContacts { services.contacts }
    func recipientSuggestions(for typed: String) -> [MailAddress] { contacts.suggestions(for: typed, addressed: [to, cc, bcc]) }

    var hasChanges: Bool { draft.snapshot != tracking.unchangedSnapshot }

    func prepare() async {
        guard !tracking.prepareStarted else { return }
        tracking.prepareStarted = true
        await runPrepare()
    }

    func retryPrepare() async {
        guard !isLoading, !isSending else { return }
        await runPrepare()
    }

    private func runPrepare() async {
        if !tracking.edited.contains(.to) { draft.to = MailRecipients.format(context.to) }
        guard context.mode != .new else {
            tracking.unchangedSnapshot = draft.snapshot
            return
        }
        status.isLoading = true
        status.loadError = nil
        defer { status.isLoading = false }
        do {
            switch try await MailComposePrefill.fetch(context, sender: sender, session: session, signIn: signIn,
                                                      cache: services.cache) {
            case .prefill(let prefill):
                apply(prefill)
            case .missingDraft:
                status.loadError = String(localized: "school_mail_error_generic")
                tracking.unchangedSnapshot = draft.snapshot
            case .nothing:
                tracking.unchangedSnapshot = draft.snapshot
            }
        } catch {
            status.loadError = MailAccountManager.LoginError(error).message
            tracking.unchangedSnapshot = MailComposeDraft().snapshot
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
        tracking.unchangedSnapshot = MailComposeDraft.snapshot(
            to: prefill.to ?? "", cc: prefill.cc ?? "", bcc: "", subject: prefill.subject, body: prefill.body,
            attachmentIDs: prefill.attachments.map(\.id))
        if let draft = prefill.draft { tracking.replacedDraft = draft }
        tracking.prefillApplied = true
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

    private func checkSignIn() -> Bool {
        if !signIn.isCurrent { status.signInEnded = true }
        return signIn.isCurrent
    }

    private func validate() -> MailRecipients.Parsed? {
        let credentials = String(localized: "school_mail_send_failed") + "\n" + MailAccountManager.LoginError.credentials.message
        guard checkAccount(credentials), let recipients = status.recipientsReportingProblems(of: draft, requireOne: true),
              status.fitsSizeLimit(draft) else { return nil }
        return recipients
    }

    func confirmationIsWarranted() -> Bool {
        guard !isSending else { return false }
        return validate() != nil
    }

    func send() async {
        guard !isSending, checkSignIn(), let recipients = validate() else { return }
        let isReply = context.mode == .reply || context.mode == .replyAll
        let threading = isReply ? context.original.map(MailReplyComposer.threadingHeaders(for:)) : nil
        let mail = outgoing(recipients, threading: threading)
        let messageID = MailMessageBuilder.makeMessageID()
        var replaced: (folder: String, draft: MailComposeSending.ReplacedDraft)?
        if context.mode == .draft, let folder = context.folder, let draft = tracking.replacedDraft {
            replaced = (folder, draft)
        }
        guard let message = await beginSending(mail, messageID: messageID) else { return }
        defer { status.isSending = false }
        do {
            let filing = try await MailComposeSending.send(MailComposeSending.Send(
                message: message, messageID: messageID, from: sender.address, recipients: mail.envelopeRecipients,
                roles: folderRoles, answered: tracking.prefillApplied && isReply ? context.message : nil, replaced: replaced
            ), session: session, services: services, signIn: signIn)
            if let refreshedRoles = filing.roles { adoptFolderRoles(refreshedRoles) }
            status.sentCopy = filing.outcome
            if let notice = MailComposeSending.notice(for: filing.outcome) { events.post(.sentCopyNotice(notice)) }
            status.didFinish = true
        } catch where !signIn.isCurrent {
            status.signInEnded = true
        } catch MailClientError.sendUnconfirmed {
            status.error = String(localized: "school_mail_send_unconfirmed")
        } catch {
            status.error = String(localized: "school_mail_send_failed") + "\n" + MailAccountManager.LoginError(error).message
        }
    }

    @discardableResult
    func saveDraft() async -> Bool {
        guard !isSending, checkSignIn(), checkAccount(MailAccountManager.LoginError.credentials.message),
              let recipients = status.recipientsReportingProblems(of: draft, requireOne: false) else { return false }
        let mail = outgoing(recipients, threading: nil)
        let savedSnapshot = draft.snapshot
        guard status.fitsSizeLimit(draft) else { return false }
        let replacesDraft = context.mode == .draft && context.folder == folderRoles[.drafts]
        let replaced = replacesDraft ? tracking.replacedDraft : nil
        guard let message = await beginSending(mail, messageID: MailMessageBuilder.makeMessageID()) else { return false }
        defer { status.isSending = false }
        do {
            let refreshedRoles = try await MailComposeSending.saveDraft(message, roles: folderRoles, replacing: replaced,
                                                                        session: session, prefs: services.prefs, signIn: signIn)
            adoptFolderRoles(refreshedRoles)
            tracking.unchangedSnapshot = savedSnapshot
            return true
        } catch where !signIn.isCurrent {
            status.signInEnded = true
            return false
        } catch is MailFolderUnavailable {
            status.error = String(localized: "school_mail_error_generic")
            return false
        } catch {
            status.error = MailAccountManager.LoginError(error).message
            return false
        }
    }

    private func beginSending(_ mail: OutgoingMail, messageID: String) async -> Data? {
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
