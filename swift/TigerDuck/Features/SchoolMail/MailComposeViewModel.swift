#if os(iOS)
import Foundation
import Observation

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
}

@MainActor
@Observable
final class MailComposeViewModel {
    nonisolated struct Attachment: Identifiable, Equatable, Sendable {
        let id = UUID()
        var filename: String
        var mimeType: String
        var data: Data
    }

    var to = "" { didSet { markEdited(&editedTo) } }
    var cc = "" { didSet { markEdited(&editedCc) } }
    var bcc = ""
    var subject = "" { didSet { markEdited(&editedSubject) } }
    var body = "" { didSet { markEdited(&editedBody) } }
    var showCcBcc = false
    private(set) var attachments: [Attachment] = []
    private(set) var isSending = false
    private(set) var isLoading = false
    private(set) var error: String? {
        didSet { errorNeedsAcknowledging = error != nil }
    }
    private(set) var errorNeedsAcknowledging = false
    private(set) var loadError: String?
    private(set) var invalidRecipients: [String] = []
    private(set) var didFinish = false
    private(set) var sentCopy: SentCopy?

    @ObservationIgnored private let context: MailComposeContext
    @ObservationIgnored private let session: MailPageSession
    @ObservationIgnored private let sender: MailAddress
    @ObservationIgnored private var folderRoles: [MailFolderRole: String]
    @ObservationIgnored var onFolderRolesChanged: (([MailFolderRole: String]) -> Void)?
    @ObservationIgnored var onSentCopyNotice: ((String) -> Void)?
    @ObservationIgnored private let prefs: any MailPreferences
    @ObservationIgnored private let cache: MailCache
    @ObservationIgnored private let sleep: (Duration) async -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var baseline = ""
    @ObservationIgnored private var prepareStarted = false
    @ObservationIgnored private var sourceLoaded = false
    @ObservationIgnored private var draftPageUIDValidity: UInt32?
    @ObservationIgnored private var draftWasAlreadyDeleted = false
    @ObservationIgnored private var suppressEditTracking = false
    @ObservationIgnored private var editedTo = false
    @ObservationIgnored private var editedCc = false
    @ObservationIgnored private var editedSubject = false
    @ObservationIgnored private var editedBody = false

    init(
        context: MailComposeContext,
        session: MailPageSession,
        sender: MailAddress,
        folderRoles: [MailFolderRole: String],
        prefs: (any MailPreferences)? = nil,
        cache: MailCache? = nil,
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.context = context
        self.session = session
        self.sender = sender
        self.folderRoles = folderRoles
        self.prefs = prefs ?? MailAccountManager.shared.prefs
        self.cache = cache ?? MailAccountManager.shared.cache
        self.sleep = sleep
        self.now = now
    }

    var hasChanges: Bool { snapshot() != baseline }

    func prepare() async {
        guard !prepareStarted else { return }
        prepareStarted = true
        await runPrepare()
    }

    func retryPrepare() async {
        guard !isLoading, !isSending else { return }
        await runPrepare()
    }

    private func runPrepare() async {
        let mode = context.mode
        applyMailtoPrefillIfNeeded(Self.format(context.to))
        guard mode != .new else {
            baseline = snapshot()
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        let folder = context.folder
        let uid = context.uid
        let forwardParts = context.attachments
        do {
            if mode == .draft {
                guard let folder, let uid else {
                    loadError = String(localized: "school_mail_error_generic")
                    baseline = snapshot()
                    return
                }
                draftPageUIDValidity = await cachedPageUIDValidity(of: folder)
                let pin = draftPageUIDValidity
                let (draft, downloaded) = try await session.use { client -> (MailMessageDetail, [Attachment]) in
                    let draft = try await client.detail(folder: folder, uid: uid, expectedUIDValidity: pin)
                    var files: [Attachment] = []
                    for part in draft.attachments {
                        let data = try await client.attachment(folder: folder, uid: uid, part: part, expectedUIDValidity: pin)
                        files.append(Attachment(filename: part.filename ?? "attachment", mimeType: part.contentType, data: data))
                    }
                    return (draft, files)
                }
                applyPrefill(
                    to: (draft.summary.to ?? []).joined(separator: ", "),
                    cc: (draft.summary.cc ?? []).joined(separator: ", "),
                    subject: draft.summary.subject ?? "",
                    body: draft.textBody ?? "",
                    showCcBcc: !(draft.summary.cc ?? []).isEmpty,
                    newAttachments: downloaded
                )
                draftWasAlreadyDeleted = draft.summary.isDeleted
                sourceLoaded = true
                return
            }

            guard let original = context.original else {
                baseline = snapshot()
                return
            }
            let dateText = original.date.map(MailDateFormatter.detailString(for:)) ?? ""
            switch mode {
            case .reply, .replyAll:
                var replyTo = original.replyTo
                if replyTo == nil, let folder, let uid {
                    let pin = await cachedPageUIDValidity(of: folder)
                    let raw = try? await session.use { client in
                        try await client.rawSource(folder: folder, uid: uid, expectedUIDValidity: pin)
                    }
                    replyTo = raw.map { MailRawHeaders.value(named: "Reply-To", in: $0).map(MailAddress.parseList) ?? [] }
                }
                let recipients = MailReplyComposer.replyRecipients(to: original, replyTo: replyTo ?? [],
                                                                   me: sender.address, replyAll: mode == .replyAll)
                applyPrefill(
                    to: Self.format(recipients.to),
                    cc: Self.format(recipients.cc),
                    subject: MailReplyComposer.replySubject(original.subject),
                    body: MailReplyComposer.quotedBody(of: original, dateText: dateText),
                    showCcBcc: !recipients.cc.isEmpty,
                    newAttachments: []
                )
                sourceLoaded = true
            case .forward:
                var pin: UInt32?
                if let folder { pin = await cachedPageUIDValidity(of: folder) }
                let downloaded: [Attachment] = try await session.use { client in
                    guard let folder, let uid else { return [] }
                    var files: [Attachment] = []
                    for part in forwardParts {
                        let data = try await client.attachment(folder: folder, uid: uid, part: part, expectedUIDValidity: pin)
                        files.append(Attachment(filename: part.filename ?? "attachment", mimeType: part.contentType, data: data))
                    }
                    return files
                }
                applyPrefill(
                    to: nil, cc: nil,
                    subject: MailReplyComposer.forwardSubject(original.subject),
                    body: MailReplyComposer.forwardBody(of: original, dateText: dateText),
                    showCcBcc: false,
                    newAttachments: downloaded
                )
                sourceLoaded = true
            case .new, .draft:
                break
            }
        } catch {
            loadError = MailAccountManager.LoginError(error).message
            baseline = Self.snapshotString(to: "", cc: "", bcc: "", subject: "", body: "", attachmentIDs: [])
        }
    }

    private func cachedPageUIDValidity(of folder: String) async -> UInt32? {
        let cache = self.cache
        return await Task.detached { cache.loadPage(folder: folder)?.uidValidity }.value
    }

    private func applyMailtoPrefillIfNeeded(_ formatted: String) {
        guard !editedTo else { return }
        suppressEditTracking = true
        to = formatted
        suppressEditTracking = false
    }

    private func applyPrefill(to: String?, cc: String?, subject: String, body: String, showCcBcc: Bool, newAttachments: [Attachment]) {
        suppressEditTracking = true
        if let to, !editedTo { self.to = to }
        if let cc, !editedCc { self.cc = cc }
        if !editedSubject { self.subject = subject }
        if !editedBody { self.body = body }
        self.showCcBcc = self.showCcBcc || showCcBcc
        suppressEditTracking = false
        let existingIDs = Set(attachments.map(\.id))
        attachments += newAttachments.filter { !existingIDs.contains($0.id) }
        baseline = Self.snapshotString(to: to ?? "", cc: cc ?? "", bcc: "", subject: subject, body: body,
                                       attachmentIDs: newAttachments.map(\.id))
    }

    private func markEdited(_ flag: inout Bool) {
        guard !suppressEditTracking else { return }
        flag = true
    }

    func addAttachment(filename: String, mimeType: String, data: Data) {
        guard !isSending else { return }
        attachments.append(Attachment(filename: filename, mimeType: mimeType, data: data))
        error = nil
    }

    func removeAttachment(_ id: Attachment.ID) {
        guard !isSending else { return }
        attachments.removeAll { $0.id == id }
    }

    func attachmentReadFailed() {
        error = String(localized: "school_mail_too_large")
    }

    func acknowledgeError() {
        errorNeedsAcknowledging = false
    }

    private func validate() -> (to: [MailAddress], cc: [MailAddress], bcc: [MailAddress])? {
        guard !prefs.authFailed else {
            error = String(localized: "school_mail_send_failed") + "\n" + MailAccountManager.LoginError.credentials.message
            return nil
        }
        error = nil
        invalidRecipients = []
        let (toList, toInvalid) = Self.parseRecipients(to)
        let (ccList, ccInvalid) = Self.parseRecipients(cc)
        let (bccList, bccInvalid) = Self.parseRecipients(bcc)
        let invalid = toInvalid + ccInvalid + bccInvalid
        guard invalid.isEmpty else {
            invalidRecipients = invalid
            error = String(format: String(localized: "school_mail_invalid_recipients"), invalid.joined(separator: ", "))
            return nil
        }
        guard !(toList + ccList + bccList).isEmpty else {
            error = String(localized: "school_mail_no_recipient")
            return nil
        }
        let attachmentBytes = attachments.map(\.data.count)
        guard MailMessageBuilder.estimateEncodedSize(body: body, attachmentByteCounts: attachmentBytes) <= MailConstants.maxEncodedMessageBytes else {
            error = String(localized: "school_mail_too_large")
            return nil
        }
        return (toList, ccList, bccList)
    }

    func confirmationIsWarranted() -> Bool {
        guard !isSending else { return false }
        return validate() != nil
    }

    func send() async {
        guard !isSending else { return }
        guard let (toList, ccList, bccList) = validate() else { return }

        let isReply = context.mode == .reply || context.mode == .replyAll
        let threading = isReply ? context.original.map(MailReplyComposer.threadingHeaders(for:)) : nil
        let mail = outgoing(to: toList, cc: ccList, bcc: bccList, threading: threading)

        let messageID = MailMessageBuilder.makeMessageID()
        let sendDate = now()
        let senderAddress = sender.address
        let knownRoles = folderRoles
        let replyFolder = (sourceLoaded && isReply) ? context.folder : nil
        let replyUID = (sourceLoaded && isReply) ? context.uid : nil
        let draftFolder = (sourceLoaded && context.mode == .draft) ? context.folder : nil
        let draftUID = (sourceLoaded && context.mode == .draft) ? context.uid : nil
        let pageUIDValidity = draftPageUIDValidity
        let draftWasDeleted = draftWasAlreadyDeleted
        let sleepFn = sleep
        let prefsRef = prefs

        isSending = true
        defer { isSending = false }
        let message = await Task.detached { MailMessageBuilder.build(mail, messageID: messageID, date: sendDate) }.value
        guard message.count <= MailConstants.maxEncodedMessageBytes else {
            error = String(localized: "school_mail_too_large")
            return
        }
        let recipients = mail.envelopeRecipients
        do {
            let filing = try await session.use { client -> SentCopyFiler.Filing in
                try await client.send(message, from: senderAddress, to: recipients)
                if let replyFolder, let replyUID {
                    try? await client.setFlag(.answered, on: true, folder: replyFolder, uids: [replyUID],
                                              expectedUIDValidity: nil)
                }
                let filing = await SentCopyFiler.file(message, messageID: messageID, in: knownRoles, client: client,
                                                      dedupeDelay: MailConstants.sentCopyDedupeDelay, sleep: sleepFn)
                if let draftFolder, let draftUID {
                    await Self.removeDraft(uid: draftUID, folder: draftFolder, client: client, prefs: prefsRef,
                                           pageUIDValidity: pageUIDValidity, wasAlreadyDeleted: draftWasDeleted)
                }
                return filing
            }
            if let refreshedRoles = filing.roles { adoptFolderRoles(refreshedRoles) }
            if filing.rejectedPassword { session.reportAuthenticationRejection() }
            sentCopy = filing.outcome
            if let notice = Self.notice(for: filing.outcome) { onSentCopyNotice?(notice) }
            didFinish = true
        } catch MailClientError.sendUnconfirmed {
            self.error = String(localized: "school_mail_send_unconfirmed")
        } catch {
            self.error = String(localized: "school_mail_send_failed") + "\n" + MailAccountManager.LoginError(error).message
        }
    }

    static func notice(for outcome: SentCopy) -> String? {
        switch outcome {
        case .filed, .serverFiledItself:
            nil
        case .notAttempted:
            String(localized: "school_mail_sent_copy_no_folder")
        case .failed(let error):
            String(localized: "school_mail_sent_copy_failed") + "\n" + MailAccountManager.LoginError(error).message
        case .unknown:
            String(localized: "school_mail_sent_copy_unknown")
        }
    }

    @discardableResult
    func saveDraft() async -> Bool {
        guard !isSending else { return false }
        guard !prefs.authFailed else {
        // A password the server rejected is never sent again: repeated failures lock the school
        // account and its Wi-Fi. SMTP `AUTH LOGIN` runs outside `MailAccountManager.openSession()`,
        // and a failed send keeps the sheet open, so each Send tap would be another login attempt.
            error = MailAccountManager.LoginError.credentials.message
            return false
        }
        error = nil
        invalidRecipients = []
        let (toList, toInvalid) = Self.parseRecipients(to)
        let (ccList, ccInvalid) = Self.parseRecipients(cc)
        let (bccList, bccInvalid) = Self.parseRecipients(bcc)
        let invalid = toInvalid + ccInvalid + bccInvalid
        guard invalid.isEmpty else {
            invalidRecipients = invalid
            error = String(format: String(localized: "school_mail_invalid_recipients"), invalid.joined(separator: ", "))
            return false
        }
        let mail = outgoing(to: toList, cc: ccList, bcc: bccList, threading: nil)
        let savedBaseline = snapshot()
        let attachmentBytes = attachments.map(\.data.count)
        guard MailMessageBuilder.estimateEncodedSize(body: body, attachmentByteCounts: attachmentBytes) <= MailConstants.maxEncodedMessageBytes else {
            error = String(localized: "school_mail_too_large")
            return false
        }

        let messageID = MailMessageBuilder.makeMessageID()
        let saveDate = now()
        let knownRoles = folderRoles
        let draftUID = (sourceLoaded && context.mode == .draft && context.folder == knownRoles[.drafts]) ? context.uid : nil
        let pageUIDValidity = draftPageUIDValidity
        let draftWasDeleted = draftWasAlreadyDeleted
        let prefsRef = prefs

        isSending = true
        defer { isSending = false }
        let message = await Task.detached { MailMessageBuilder.build(mail, messageID: messageID, date: saveDate) }.value
        guard message.count <= MailConstants.maxEncodedMessageBytes else {
            error = String(localized: "school_mail_too_large")
            return false
        }
        do {
            let refreshedRoles = try await session.use { client -> [MailFolderRole: String] in
                guard let drafts = await MailFolderProvisioner.ensure(.drafts, in: knownRoles, client: client) else {
                    throw MailFolderUnavailable(role: .drafts)
                }
                try await client.append(message, to: drafts.name, flags: [.draft, .seen])
                if let draftUID {
                    await Self.removeDraft(uid: draftUID, folder: drafts.name, client: client, prefs: prefsRef,
                                           pageUIDValidity: pageUIDValidity, wasAlreadyDeleted: draftWasDeleted)
                }
                return drafts.roles
            }
            adoptFolderRoles(refreshedRoles)
            baseline = savedBaseline
            return true
        } catch is MailFolderUnavailable {
            error = String(localized: "school_mail_error_generic")
            return false
        } catch {
            self.error = MailAccountManager.LoginError(error).message
            return false
        }
    }

    private func adoptFolderRoles(_ roles: [MailFolderRole: String]) {
        guard roles != folderRoles else { return }
        folderRoles = roles
        onFolderRolesChanged?(roles)
    }

    private func outgoing(to: [MailAddress], cc: [MailAddress], bcc: [MailAddress],
                          threading: (inReplyTo: String?, references: [String])?) -> OutgoingMail {
        OutgoingMail(
            from: sender, to: to, cc: cc, bcc: bcc, subject: subject, body: body,
            inReplyTo: threading?.inReplyTo, references: threading?.references ?? [],
            attachments: attachments.map { OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
        )
    }

    private static func removeDraft(uid: UInt32, folder: String, client: any MailClient, prefs: any MailPreferences,
                                    pageUIDValidity: UInt32?, wasAlreadyDeleted: Bool) async {
        guard let pageUIDValidity else { return }
        let owned = prefs.ownedDeleted(folder: folder, uidValidity: pageUIDValidity)
        do {
            let result = try await MailMover.deletePermanently(uids: [uid], in: folder, client: client, previouslyFlagged: owned)
            prefs.setOwnedDeleted(result.stillPending)
        } catch {
            guard let claim = await MailMover.recoverAfterFailure(after: error, uid: uid, previouslyFlagged: owned,
                                                                  client: client, wasAlreadyDeleted: wasAlreadyDeleted) else {
                return
            }
            prefs.setOwnedDeleted(claim)
        }
    }

    private func snapshot() -> String {
        Self.snapshotString(to: to, cc: cc, bcc: bcc, subject: subject, body: body, attachmentIDs: attachments.map(\.id))
    }

    private static func snapshotString(to: String, cc: String, bcc: String, subject: String, body: String, attachmentIDs: [Attachment.ID]) -> String {
        [to, cc, bcc, subject, body, attachmentIDs.map(\.uuidString).joined()].joined(separator: "\u{1F}")
    }

    private static func format(_ addresses: [MailAddress]) -> String {
        addresses.map { address in
            guard let name = address.name?.mailNonEmpty else { return address.address }
            let needsQuotes = name.contains(",") || name.contains(";")
            return needsQuotes ? "\"\(name)\" <\(address.address)>" : "\(name) <\(address.address)>"
        }.joined(separator: ", ")
    }

    private static func parseRecipients(_ raw: String) -> (addresses: [MailAddress], invalid: [String]) {
        var addresses: [MailAddress] = []
        var invalid: [String] = []
        for token in splitTopLevel(raw) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let address = sendableAddress(trimmed) {
                addresses.append(address)
            } else {
                invalid.append(trimmed)
            }
        }
        return (addresses, invalid)
    }

    nonisolated static func sendableAddress(_ token: String) -> MailAddress? {
        guard let address = MailAddress.parseList(token).first,
              address.address.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        return address
    }

    private static func splitTopLevel(_ raw: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        var escaped = false
        for character in raw {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
        // Saving a draft is an IMAP APPEND, which needs the saved password, and a password the
        // server rejected is never sent again: repeated failures lock the account and its Wi-Fi.
            if character == "\\", inQuotes {
                current.append(character)
                escaped = true
                continue
            }
            if character == "\"" { inQuotes.toggle() }
            if character == "<", !inQuotes { inAngle = true }
            if character == ">", !inQuotes { inAngle = false }
            if (character == "," || character == ";") && !inQuotes && !inAngle {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)
        return pieces
    }
}
#endif
            // The STORE may already have landed; an unclaimed `\Deleted` UID blocks every later
            // EXPUNGE in Drafts for good, so the same recovery the message screen runs applies
            // here.
    /// Splits on top-level commas and semicolons, mirroring `MailAddress.parseList`'s quote- and
    /// angle-bracket-aware algorithm. It is duplicated because that call silently drops a token it
    /// can't parse, and compose needs the raw token back to report it. A token's original text is
    /// kept as invalid when it doesn't parse to a plausible address, or its local part or domain
    /// carries a non-ASCII character. The school SMTP server has no SMTPUTF8, so such a token is
    /// rejected only here, in compose validation, never in the shared address parser incoming mail
    /// uses to show a "From".
