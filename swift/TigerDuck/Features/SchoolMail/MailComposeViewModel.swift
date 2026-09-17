#if os(iOS)
import Foundation
import Observation

nonisolated enum MailComposeMode: Equatable, Sendable {
    case new, reply, replyAll, forward, draft
}

nonisolated struct MailComposeContext: Identifiable, Sendable {
    let id = UUID()
    var mode: MailComposeMode
    /// The original's folder and UID (for `.draft`, the draft being edited).
    var folder: String?
    var uid: UInt32?
    var original: MailOriginal?
    /// `.forward`: the original's attachments, fetched on `prepare()`.
    var attachments: [MailBodyPart] = []
    /// `.new` from a `mailto:` link.
    var to: [MailAddress] = []
}

/// Plain-text compose (design doc §6.4) and sending (§8.4). Nothing here stages files to disk —
/// every attachment (locally picked or carried from the original) is held as `Data` in memory for
/// the lifetime of the sheet, unlike the Android reference's lazy `InputStream`/staged-file model.
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
    private(set) var error: String?
    /// A failed `prepare()`/`retryPrepare()`, kept entirely separate from `error`: an attachment
    /// change or a send/save validation error or failure must never clear the Retry action this
    /// drives, and a successful load is the only thing that clears it (dispatch addition 5).
    private(set) var loadError: String?
    private(set) var invalidRecipients: [String] = []
    private(set) var didFinish = false

    @ObservationIgnored private let context: MailComposeContext
    @ObservationIgnored private let session: MailPageSession
    @ObservationIgnored private let sender: MailAddress
    @ObservationIgnored private let folderRoles: [MailFolderRole: String]
    @ObservationIgnored private let prefs: any MailPreferences
    @ObservationIgnored private let sleep: (Duration) async -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var baseline = ""
    @ObservationIgnored private var prepareStarted = false
    /// True only once `prepare()`/`retryPrepare()` actually finished loading the original mail or
    /// the draft being edited -- gates marking an original "answered" and replacing/removing a
    /// draft, so a load that never finished (or failed) can never do either (dispatch addition 5).
    @ObservationIgnored private var sourceLoaded = false
    /// Suppresses the `didSet` edit-tracking below while `runPrepare()` writes a freshly computed
    /// prefill value into a field -- that write must never be mistaken for something the user typed.
    @ObservationIgnored private var suppressEditTracking = false
    /// Which text fields the user has typed into this session (in-memory only). A successful load
    /// keeps an edited field's current value instead of overwriting it with the freshly computed
    /// one -- both on the very first `prepare()` (unlikely to matter, since fields start blank) and
    /// on `retryPrepare()` after a failure, which is the case this actually protects.
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
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.context = context
        self.session = session
        self.sender = sender
        self.folderRoles = folderRoles
        self.prefs = prefs ?? MailAccountManager.shared.prefs
        self.sleep = sleep
        self.now = now
    }

    var hasChanges: Bool { snapshot() != baseline }

    // MARK: Loading

    /// Fills the fields for the mode; runs once per instance. See `retryPrepare()`.
    func prepare() async {
        guard !prepareStarted else { return }
        prepareStarted = true
        await runPrepare()
    }

    /// Retries after a failed `prepare()`. Refuses to overlap a load already running, but is
    /// otherwise unguarded -- the view only ever wires this to the Retry affordance it shows
    /// while `loadError` is set.
    func retryPrepare() async {
        guard !isLoading else { return }
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
                    return
                }
                let (draft, downloaded) = try await session.use { client -> (MailMessageDetail, [Attachment]) in
                    let draft = try await client.detail(folder: folder, uid: uid)
                    var files: [Attachment] = []
                    for part in draft.attachments {
                        let data = try await client.attachment(folder: folder, uid: uid, part: part)
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
                sourceLoaded = true
                baseline = snapshot()
                return
            }

            guard let original = context.original else { return }
            let dateText = original.date.map(MailDateFormatter.detailString(for:)) ?? ""
            switch mode {
            case .reply, .replyAll:
                let replyTo: [MailAddress] = try await session.use { client in
                    guard let folder, let uid else { return [] }
                    let raw = try await client.rawSource(folder: folder, uid: uid)
                    return MailRawHeaders.value(named: "Reply-To", in: raw).map(MailAddress.parseList) ?? []
                }
                let recipients = MailReplyComposer.replyRecipients(to: original, replyTo: replyTo, me: sender.address,
                                                                   replyAll: mode == .replyAll)
                applyPrefill(
                    to: Self.format(recipients.to),
                    cc: Self.format(recipients.cc),
                    subject: MailReplyComposer.replySubject(original.subject),
                    body: MailReplyComposer.quotedBody(of: original, dateText: dateText),
                    showCcBcc: !recipients.cc.isEmpty,
                    newAttachments: []
                )
                sourceLoaded = true
                baseline = snapshot()
            case .forward:
                let downloaded: [Attachment] = try await session.use { client in
                    guard let folder, let uid else { return [] }
                    var files: [Attachment] = []
                    for part in forwardParts {
                        let data = try await client.attachment(folder: folder, uid: uid, part: part)
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
                baseline = snapshot()
            case .new, .draft:
                break
            }
        } catch {
            loadError = MailAccountManager.LoginError(error).message
        }
    }

    private func applyMailtoPrefillIfNeeded(_ formatted: String) {
        guard !editedTo else { return }
        suppressEditTracking = true
        to = formatted
        suppressEditTracking = false
    }

    /// Applies a freshly computed prefill: an edited field keeps the user's current value; a
    /// `nil` `to`/`cc` (forward, which never prefills recipients) leaves that field untouched
    /// either way. Newly downloaded attachments are always added alongside whatever the user
    /// already picked -- never replacing that list (dispatch addition 5).
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
    }

    private func markEdited(_ flag: inout Bool) {
        guard !suppressEditTracking else { return }
        flag = true
    }

    // MARK: Attachments

    func addAttachment(filename: String, mimeType: String, data: Data) {
        attachments.append(Attachment(filename: filename, mimeType: mimeType, data: data))
        error = nil
    }

    func removeAttachment(_ id: Attachment.ID) {
        attachments.removeAll { $0.id == id }
    }

    /// A locally picked file whose bytes couldn't be read off the main actor -- shown the same
    /// way an over-budget attachment would be (dispatch addition 3: never silently dropped, never
    /// treated as a 0-byte attachment).
    func attachmentReadFailed() {
        error = String(localized: "school_mail_too_large")
    }

    // MARK: Sending

    func send() async {
        guard !isSending else { return }
        error = nil
        invalidRecipients = []
        let (toList, toInvalid) = Self.parseRecipients(to)
        let (ccList, ccInvalid) = Self.parseRecipients(cc)
        let (bccList, bccInvalid) = Self.parseRecipients(bcc)
        let invalid = toInvalid + ccInvalid + bccInvalid
        guard invalid.isEmpty else {
            invalidRecipients = invalid
            error = String(format: String(localized: "school_mail_invalid_recipients"), invalid.joined(separator: ", "))
            return
        }
        let everyone = toList + ccList + bccList
        guard !everyone.isEmpty else {
            error = String(localized: "school_mail_no_recipient")
            return
        }

        let isReply = context.mode == .reply || context.mode == .replyAll
        let threading = (sourceLoaded && isReply) ? context.original.map(MailReplyComposer.threadingHeaders(for:)) : nil
        let mail = outgoing(to: toList, cc: ccList, bcc: bccList, threading: threading)
        let messageID = MailMessageBuilder.makeMessageID()
        let message = MailMessageBuilder.build(mail, messageID: messageID, date: now())
        guard message.count <= MailConstants.maxEncodedMessageBytes else {
            error = String(localized: "school_mail_too_large")
            return
        }

        let recipients = mail.envelopeRecipients
        let senderAddress = sender.address
        let sentFolder = folderRoles[.sent]
        let replyFolder = (sourceLoaded && isReply) ? context.folder : nil
        let replyUID = (sourceLoaded && isReply) ? context.uid : nil
        let draftFolder = (sourceLoaded && context.mode == .draft) ? context.folder : nil
        let draftUID = (sourceLoaded && context.mode == .draft) ? context.uid : nil
        let sleepFn = sleep
        let prefsRef = prefs

        isSending = true
        defer { isSending = false }
        do {
            try await session.use { client in
                try await client.send(message, from: senderAddress, to: recipients)
                if let replyFolder, let replyUID {
                    try? await client.setFlag(.answered, on: true, folder: replyFolder, uids: [replyUID])
                }
                if let sentFolder {
                    // Save a sent copy only if the server did not file one itself (§8.4).
                    await sleepFn(MailConstants.sentCopyDedupeDelay)
                    let alreadySaved = (try? await client.containsMessageID(messageID, in: sentFolder)) ?? false
                    if !alreadySaved {
                        try? await client.append(message, to: sentFolder, flags: [.seen])
                    }
                }
                if let draftFolder, let draftUID {
                    await Self.removeDraft(uid: draftUID, folder: draftFolder, client: client, prefs: prefsRef)
                }
            }
            didFinish = true
        } catch MailClientError.folderChanged {
            // Shown as-is, never retried here -- the list recovers through its own path the next
            // time the user opens it (dispatch addition 6).
            self.error = String(localized: "school_mail_send_failed") + "\n" + MailAccountManager.LoginError(MailClientError.folderChanged).message
        } catch {
            self.error = String(localized: "school_mail_send_failed") + "\n" + MailAccountManager.LoginError(error).message
        }
    }

    /// Saves to 草稿匣 with `\Draft`; editing a draft saves a new one and deletes the old. Runs the
    /// same recipient and size validation `send()` does (dispatch addition 1 and 3) -- a draft may
    /// legitimately have no recipients yet, only a token that couldn't be parsed, or an over-budget
    /// attachment, blocks saving.
    @discardableResult
    func saveDraft() async -> Bool {
        guard !isSending else { return false }
        guard let drafts = folderRoles[.drafts] else { return false }
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
        let message = MailMessageBuilder.build(mail, messageID: MailMessageBuilder.makeMessageID(), date: now())
        guard message.count <= MailConstants.maxEncodedMessageBytes else {
            error = String(localized: "school_mail_too_large")
            return false
        }

        let draftUID = (sourceLoaded && context.mode == .draft && context.folder == drafts) ? context.uid : nil
        let prefsRef = prefs
        isSending = true
        defer { isSending = false }
        do {
            try await session.use { client in
                try await client.append(message, to: drafts, flags: [.draft, .seen])
                if let draftUID {
                    await Self.removeDraft(uid: draftUID, folder: drafts, client: client, prefs: prefsRef)
                }
            }
            baseline = snapshot()
            return true
        } catch {
            self.error = MailAccountManager.LoginError(error).message
            return false
        }
    }

    // MARK: Internals

    private func outgoing(to: [MailAddress], cc: [MailAddress], bcc: [MailAddress],
                          threading: (inReplyTo: String?, references: [String])?) -> OutgoingMail {
        OutgoingMail(
            from: sender, to: to, cc: cc, bcc: bcc, subject: subject, body: body,
            inReplyTo: threading?.inReplyTo, references: threading?.references ?? [],
            attachments: attachments.map { OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
        )
    }

    /// Uses `prefs.ownedDeleted(folder:uidValidity:)`/`setOwnedDeleted(_:)` with the folder's fresh
    /// UIDVALIDITY (dispatch addition 6) -- `static` and taking every dependency as a parameter so
    /// it never captures `self` across the `session.use` closure it runs inside.
    private static func removeDraft(uid: UInt32, folder: String, client: any MailClient, prefs: any MailPreferences) async {
        guard let status = try? await client.status(folder: folder) else { return }
        let owned = prefs.ownedDeleted(folder: folder, uidValidity: status.uidValidity)
        guard let result = try? await MailMover.deletePermanently(uids: [uid], in: folder, client: client, previouslyFlagged: owned) else { return }
        prefs.setOwnedDeleted(result.stillPending)
    }

    private func snapshot() -> String {
        [to, cc, bcc, subject, body, attachments.map(\.id.uuidString).joined()].joined(separator: "\u{1F}")
    }

    /// `Name <address>`, quoting names that contain a separator.
    private static func format(_ addresses: [MailAddress]) -> String {
        addresses.map { address in
            guard let name = address.name?.mailNonEmpty else { return address.address }
            let needsQuotes = name.contains(",") || name.contains(";")
            return needsQuotes ? "\"\(name)\" <\(address.address)>" : "\(name) <\(address.address)>"
        }.joined(separator: ", ")
    }

    /// Splits on top-level commas/semicolons (mirroring `MailAddress.parseList`'s own quote- and
    /// angle-bracket-aware algorithm, duplicated here because that call silently drops a token it
    /// can't parse -- compose needs the raw token back to report it) and keeps a token's original
    /// text as invalid when it doesn't parse to a plausible address, or does but its local part or
    /// domain carries a non-ASCII character -- the school SMTP server has no SMTPUTF8, so such a
    /// token is only ever rejected here, in compose validation, never in the shared address parser
    /// incoming mail uses to show a "From" (dispatch addition 1).
    private static func parseRecipients(_ raw: String) -> (addresses: [MailAddress], invalid: [String]) {
        var addresses: [MailAddress] = []
        var invalid: [String] = []
        var seen = Set<String>()
        for token in splitTopLevel(raw) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let address = MailAddress.parseList(trimmed).first, address.address.unicodeScalars.allSatisfy(\.isASCII) {
                if seen.insert(address.address.lowercased()).inserted { addresses.append(address) }
            } else {
                invalid.append(trimmed)
            }
        }
        return (addresses, invalid)
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
