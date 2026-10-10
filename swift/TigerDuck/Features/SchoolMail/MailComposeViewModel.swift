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

/// Plain-text compose and sending. Nothing here stages files to disk: every attachment (locally
/// picked or carried from the original) is held as `Data` in memory for the lifetime of the
/// sheet, unlike the Android reference's lazy `InputStream`/staged-file model.
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
    /// Every assignment raises `errorNeedsAcknowledging` — see that property for why this is a
    /// `didSet` rather than something each of the half-dozen assignment sites remembers to do.
    private(set) var error: String? {
        didSet { errorNeedsAcknowledging = error != nil }
    }
    /// A send or save failure the user has not dismissed yet: small red text under a long form is
    /// easy to scroll past, so the same message is also put in a dialog they have to acknowledge.
    ///
    /// A flag rather than something derived from `error`: tapping Send again after dismissing an
    /// error, with nothing changed, sets the same `String`, so anything comparing error values
    /// (`.alert(item:)`, `onChange(of:)`) would see no change and swallow the second dialog. Any
    /// non-nil `error` assignment raises it; `acknowledgeError()` or clearing `error` lowers it.
    private(set) var errorNeedsAcknowledging = false
    /// A failed `prepare()`/`retryPrepare()`, kept entirely separate from `error`: an attachment
    /// change or a send/save validation error or failure must never clear the Retry action this
    /// drives. Only a successful load clears it.
    private(set) var loadError: String?
    private(set) var invalidRecipients: [String] = []
    private(set) var didFinish = false
    /// What became of the copy of the mail this sheet sent — `nil` until a send has finished.
    /// Never `error`: the mail went out, and none of these outcomes is a failed send.
    private(set) var sentCopy: SentCopy?

    @ObservationIgnored private let context: MailComposeContext
    @ObservationIgnored private let session: MailPageSession
    @ObservationIgnored private let sender: MailAddress
    /// The account's role folders as the list resolved them, updated in place when `send()` or
    /// `saveDraft()` has to create one that was missing. Nothing on this screen renders it, so it
    /// stays out of the observation graph.
    @ObservationIgnored private var folderRoles: [MailFolderRole: String]
    /// Reports a role map re-resolved after creating a folder on demand, so the screen that
    /// presented this sheet — and through it the list, which resolves its own map once per
    /// session — stops believing the folder does not exist.
    @ObservationIgnored var onFolderRolesChanged: (([MailFolderRole: String]) -> Void)?
    /// Reports a sent copy that was not kept, to the screen that presented this sheet — this one
    /// dismisses the moment the send succeeds, so it is not somewhere a notice can be read. Only
    /// ever called for an outcome worth telling the user about; a copy that was filed (by either
    /// side) says nothing.
    @ObservationIgnored var onSentCopyNotice: ((String) -> Void)?
    @ObservationIgnored private let prefs: any MailPreferences
    @ObservationIgnored private let cache: MailCache
    @ObservationIgnored private let sleep: (Duration) async -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var baseline = ""
    @ObservationIgnored private var prepareStarted = false
    /// True only once `prepare()`/`retryPrepare()` finished loading the original mail or the
    /// draft being edited. It gates marking an original "answered" and replacing or removing a
    /// draft, so a load that never finished (or failed) can do neither.
    @ObservationIgnored private var sourceLoaded = false
    /// The Drafts page's UIDVALIDITY as cached by the list (`.draft` mode only), read once during
    /// `prepare()`/`retryPrepare()`. `removeDraft` uses this, never a value read fresh right
    /// before `MailMover` runs: its freshness guard would then compare a value against itself
    /// and could never refuse. Mirrors `MailMessageViewModel.pageUIDValidity`.
    @ObservationIgnored private var draftPageUIDValidity: UInt32?
    /// Whether the draft being edited was already `\Deleted` when it was loaded — a message
    /// someone else deleted must never become one TigerDuck claims just because its own STORE
    /// also touched it. Read once during `prepare()`, like `draftPageUIDValidity`.
    @ObservationIgnored private var draftWasAlreadyDeleted = false
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

    // MARK: Loading

    /// Fills the fields for the mode; runs once per instance. See `retryPrepare()`.
    func prepare() async {
        guard !prepareStarted else { return }
        prepareStarted = true
        await runPrepare()
    }

    /// Retries after a failed `prepare()`. Refuses to overlap a load already running, or a
    /// send/save in flight, but is otherwise unguarded: the view only wires this to the Retry
    /// affordance it shows while `loadError` is set.
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
                // The generation this draft's UID was read under — the same pin `removeDraft`
                // uses. A folder recreated since would make this UID someone else's message, and
                // the compose form would open on it (and go on to delete it after sending).
                let pin = draftPageUIDValidity
                let (draft, downloaded) = try await session.use { client -> (MailMessageDetail, [Attachment]) in
                    let draft = try await client.detail(folder: folder, uid: uid, expectedUIDValidity: pin)
                    var files: [Attachment] = []
                    for part in draft.attachments {
                        // The same pin as the `detail` above, not none: the part list was read
                        // under that generation, and a recreation between the two fetches would
                        // hand this form another message's files to re-attach and send.
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
                // Best-effort: everything else a reply prefill needs is in `context.original`, so a
                // failed Reply-To download must not empty the form or drop threading. Replies then
                // go to the sender's own address, as if the mail had no Reply-To header.
                var replyTo: [MailAddress] = []
                if let folder, let uid, let raw = try? await session.use({ client in try await client.rawSource(folder: folder, uid: uid) }) {
                    replyTo = MailRawHeaders.value(named: "Reply-To", in: raw).map(MailAddress.parseList) ?? []
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
            case .forward:
                // The pin comes from the cached page, as in the draft branch: the message screen
                // pinned its `detail` to that page's `pageUIDValidity`, so parts and pin share one
                // generation, with no pin threaded through `MailComposeContext` by each presenter.
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
            // The empty-form value, not `snapshot()`: a retry that fails again after the user typed
            // must not fold that edit into the baseline, as a successful `applyPrefill` must not.
            // With nothing typed yet, `snapshot()` would match this anyway.
            baseline = Self.snapshotString(to: "", cc: "", bcc: "", subject: "", body: "", attachmentIDs: [])
        }
    }

    /// The UIDVALIDITY generation the list cached this folder's page under — the only generation
    /// this screen ever knows, and the one every UID it was handed was read under. Detached
    /// because `MailCache` does synchronous disk I/O and this type is `@MainActor`.
    ///
    /// Read fresh from the cache rather than from the server: a value fetched from the server
    /// right before the command that needs it would be compared against itself and could never
    /// refuse (the same reasoning as `draftPageUIDValidity` and `MailMessageViewModel.pageUIDValidity`).
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

    /// Applies a freshly computed prefill. Edited fields keep the user's value, a `nil` `to`/`cc`
    /// (forward never prefills recipients) stays untouched, and downloaded attachments join the
    /// user's own instead of replacing them.
    ///
    /// `baseline` is built from the prefill values alone, not the merged fields, so a field the
    /// user edited still counts toward `hasChanges` and Cancel cannot silently discard it. Its
    /// `bcc` is "" since no prefill sets it and Bcc is never written as a header. As on Android,
    /// its attachments are only `newAttachments`, so a file picked before a retry stays dirty too.
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

    // MARK: Attachments

    /// Refused while a send or save is in flight: `send()`/`saveDraft()` snapshot the
    /// attachments into the message before their round trip, so accepting one here would leave
    /// a file listed on screen that was never in the mail the server got — and the sheet then
    /// dismisses. The view keeps this unreachable from the UI (the form is disabled for the
    /// duration, and Send stays disabled while any pick is still being read off the main
    /// actor); this is the last line of that defence, not the first.
    func addAttachment(filename: String, mimeType: String, data: Data) {
        guard !isSending else { return }
        attachments.append(Attachment(filename: filename, mimeType: mimeType, data: data))
        error = nil
    }

    func removeAttachment(_ id: Attachment.ID) {
        guard !isSending else { return }
        attachments.removeAll { $0.id == id }
    }

    /// A locally picked file whose bytes couldn't be read off the main actor. It is shown the
    /// same way an over-budget attachment would be: never silently dropped, never treated as a
    /// 0-byte attachment.
    func attachmentReadFailed() {
        error = String(localized: "school_mail_too_large")
    }

    /// The user dismissed the error dialog. Deliberately leaves `error` alone: the inline message
    /// under the form is the copy they can go back and read, and clearing it here would make
    /// dismissing the dialog erase the only lasting record of what went wrong.
    func acknowledgeError() {
        errorNeedsAcknowledging = false
    }

    // MARK: Sending

    /// Everything that can refuse a send before a byte leaves the phone, reporting the refusal
    /// exactly as `send()` always has and handing back the parsed recipients when there is none.
    ///
    /// Split out so Send can ask "Send this mail?" *after* the form has been judged rather than
    /// before: a mail that would only fail validation anyway gets the error it would have got,
    /// and the confirmation is reserved for a mail that really is about to go out. `send()` runs
    /// it again for itself, so the check is never something a caller can skip.
    private func validate() -> (to: [MailAddress], cc: [MailAddress], bcc: [MailAddress])? {
        // A password the server rejected is never sent again: repeated failures lock the school
        // account and its Wi-Fi. SMTP `AUTH LOGIN` runs outside `MailAccountManager.openSession()`,
        // and a failed send keeps the sheet open, so each Send tap would be another login attempt.
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

    /// Run when Send is tapped, before the "Send this mail?" confirmation: `true` means the mail
    /// would actually send and the confirmation is worth raising. A refusal has already set
    /// `error` (and raised the dialog that goes with it), and no confirmation follows — the user
    /// is never asked to confirm a send that was never going to happen. Refuses outright while a
    /// send is in flight, so the question cannot be put a second time over one already running.
    func confirmationIsWarranted() -> Bool {
        guard !isSending else { return false }
        return validate() != nil
    }

    func send() async {
        guard !isSending else { return }
        guard let (toList, ccList, bccList) = validate() else { return }

        let isReply = context.mode == .reply || context.mode == .replyAll
        // Threading needs only `context.original`, in-memory data, so it is not gated on
        // `sourceLoaded`: a reply whose Reply-To fetch failed (best-effort, see `runPrepare`)
        // still goes out In-Reply-To the right message.
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

        // The busy state is set before the off-main build so the sheet can't be dismissed or
        // re-sent while a large message is still being assembled.
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
                    // No pin: compose has the Drafts page's UIDVALIDITY, not the original folder's.
                    // A recreated folder costs at most a cosmetic `\Answered` flag on the wrong
                    // message; the pinned calls below could destroy mail, so only they require one.
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
            // A rejected password on the APPEND (or a probe) must reach the sign-in path's choke
            // point, or the next Send tap sends it again. Filing the copy is best-effort and must
            // not fail a send that succeeded, so it is reported here instead of thrown.
            if filing.rejectedPassword { session.reportAuthenticationRejection() }
            // The copy is a notice, never a failure: the mail went out either way, so `send()`
            // reports success and the screen that presented this sheet shows what became of the
            // copy. Raised before `didFinish`, which is what dismisses the sheet.
            sentCopy = filing.outcome
            if let notice = Self.notice(for: filing.outcome) { onSentCopyNotice?(notice) }
            didFinish = true
        } catch {
            // The mail is never retried here on any error, `folderChanged` included: the list
            // recovers through its own path the next time the user opens it.
            self.error = String(localized: "school_mail_send_failed") + "\n" + MailAccountManager.LoginError(error).message
        }
    }

    /// The one line the user sees about a sent copy, or `nil` when there is nothing to say.
    ///
    /// The three that do say something are deliberately distinct, because what the user can do
    /// about them is: "no Sent folder" is actionable (make one in the webmail, or accept that
    /// this account keeps no copies), "the copy couldn't be saved" is retryable (the mail is in
    /// the list it was sent from, and the next send may well work), and "couldn't tell" is
    /// neither — it is an honest admission that TigerDuck declined to guess rather than risk
    /// filing the mail twice.
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

    /// Saves to Drafts with `\Draft`; editing a draft saves a new one and deletes the old. Runs the
    /// same recipient and size validation `send()` does, except that a draft may have no
    /// recipients yet: only a token that couldn't be parsed, or an over-budget attachment, blocks
    /// saving.
    ///
    /// A missing Drafts folder is created only once every check has passed and the message is
    /// built, so a save that was never going to happen leaves no folder behind. A failed CREATE
    /// shows the missing-Drafts error, because the user has to know the draft was not kept.
    @discardableResult
    func saveDraft() async -> Bool {
        guard !isSending else { return false }
        // Saving a draft is an IMAP APPEND, which needs the saved password, and a password the
        // server rejected is never sent again: repeated failures lock the account and its Wi-Fi.
        guard !prefs.authFailed else {
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
        // Taken from the same reading of the fields that went into `mail`, not after the append:
        // anything added in between is not on the server, and counting it as saved would make
        // `hasChanges` report clean and let the leave dialog dismiss the sheet over it.
        let savedBaseline = snapshot()
        let attachmentBytes = attachments.map(\.data.count)
        guard MailMessageBuilder.estimateEncodedSize(body: body, attachmentByteCounts: attachmentBytes) <= MailConstants.maxEncodedMessageBytes else {
            error = String(localized: "school_mail_too_large")
            return false
        }

        let messageID = MailMessageBuilder.makeMessageID()
        let saveDate = now()
        let knownRoles = folderRoles
        // Against the map as it stands, deliberately: a draft can only have been opened from a
        // Drafts folder that already resolved, so a `nil` here is a mode that cannot be `.draft`.
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
            // Set an error rather than failing silently: the confirmation dialog's Save button
            // would otherwise do nothing with no explanation.
            error = String(localized: "school_mail_error_generic")
            return false
        } catch {
            self.error = MailAccountManager.LoginError(error).message
            return false
        }
    }

    /// Takes on a role map the provisioner re-resolved from a fresh folder list, and tells the
    /// screen that presented this sheet — nothing above knows a folder was created otherwise.
    private func adoptFolderRoles(_ roles: [MailFolderRole: String]) {
        guard roles != folderRoles else { return }
        folderRoles = roles
        onFolderRolesChanged?(roles)
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

    /// Uses `prefs.ownedDeleted(folder:uidValidity:)`/`setOwnedDeleted(_:)` with the page's
    /// UIDVALIDITY, never one read fresh here: `MailMover.deletePermanently`'s freshness guard
    /// would then compare a value against itself and could never refuse (the same shape as
    /// `MailMessageViewModel.performMove`). With no cached page UIDVALIDITY to check against it
    /// does nothing, leaving the old draft behind, which is harmless as the new one is saved.
    /// `static`, with every dependency as a parameter, so it never captures `self` across the
    /// `session.use` closure it runs inside.
    private static func removeDraft(uid: UInt32, folder: String, client: any MailClient, prefs: any MailPreferences,
                                    pageUIDValidity: UInt32?, wasAlreadyDeleted: Bool) async {
        guard let pageUIDValidity else { return }
        let owned = prefs.ownedDeleted(folder: folder, uidValidity: pageUIDValidity)
        do {
            let result = try await MailMover.deletePermanently(uids: [uid], in: folder, client: client, previouslyFlagged: owned)
            prefs.setOwnedDeleted(result.stillPending)
        } catch {
            // The STORE may already have landed; an unclaimed `\Deleted` UID blocks every later
            // EXPUNGE in Drafts for good, so the same recovery the message screen runs applies
            // here.
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

    /// `Name <address>`, quoting names that contain a separator.
    private static func format(_ addresses: [MailAddress]) -> String {
        addresses.map { address in
            guard let name = address.name?.mailNonEmpty else { return address.address }
            let needsQuotes = name.contains(",") || name.contains(";")
            return needsQuotes ? "\"\(name)\" <\(address.address)>" : "\(name) <\(address.address)>"
        }.joined(separator: ", ")
    }

    /// Splits on top-level commas and semicolons, mirroring `MailAddress.parseList`'s quote- and
    /// angle-bracket-aware algorithm. It is duplicated because that call silently drops a token it
    /// can't parse, and compose needs the raw token back to report it. A token's original text is
    /// kept as invalid when it doesn't parse to a plausible address, or its local part or domain
    /// carries a non-ASCII character. The school SMTP server has no SMTPUTF8, so such a token is
    /// rejected only here, in compose validation, never in the shared address parser incoming mail
    /// uses to show a "From".
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

    /// One recipient token as `send()` would take it, or `nil` when `send()` would refuse it —
    /// the rule the compose screen's recipient bubbles mark an invalid one by.
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
