#if os(iOS)
import Foundation
import Observation

struct MailMessageRoute: Hashable {
    var folder: String
    var uid: UInt32
}

/// One tapped link — judged, shown and opened as the SAME canonicalized string (message-screen
/// dispatch, 2026-09-16 additions 1–2). `canOpen` is false only for an http(s) href a
/// browser-style parse rejects; the dialog then still shows it (bidi-stripped) but without an
/// Open action. `id` is the href itself: this value only ever backs one transient confirmation
/// sheet at a time, never a list, so a repeated href across separate taps is not a problem.
nonisolated struct MailLinkTarget: Equatable, Sendable, Identifiable {
    var href: String
    var issues: [MailLinkIssue]
    var canOpen: Bool
    var id: String { href }
}

@MainActor
@Observable
final class MailMessageViewModel {
    enum ViewMode: String, CaseIterable, Identifiable {
        case formatted, plain, source
        var id: String { rawValue }
        var title: String {
            switch self {
            case .formatted: String(localized: "school_mail_view_formatted")
            case .plain: String(localized: "school_mail_view_plain")
            case .source: String(localized: "school_mail_view_source")
            }
        }
    }

    enum LoadState: Equatable {
        case loading, loaded
        case failed(String)
    }

    let route: MailMessageRoute
    private(set) var detail: MailMessageDetail?
    private(set) var loadState: LoadState = .loading
    private(set) var sanitized: SanitizedHTML?
    /// `sanitized.html`, with every `<a href>` rewritten to an index into `linkedDocument.links`
    /// — what the web view actually loads. See `linkTarget(forIndex:)`.
    private(set) var linkedDocument: LinkedHTML?
    private(set) var plainText = ""
    private(set) var warnings: [MailWarning] = []
    private(set) var parseFailed = false
    private(set) var source: String?
    private(set) var needsSourceConfirmation = false
    /// Set when `loadSource` throws, cleared at the start of the next attempt — lets the
    /// source view show a retryable failed state instead of spinning forever (fix round 1,
    /// minor 6).
    private(set) var sourceLoadFailed = false
    private(set) var allowRemoteImages = false
    private(set) var actionError: String?
    /// True for the whole of a move or delete — four to five IMAP round trips with nothing on
    /// screen to say so. The view disables every affordance that starts one while it is set;
    /// `performMove` refuses as well, so a tap the view somehow lets through still cannot file
    /// the same mail into two folders.
    private(set) var isMoving = false
    var mode: ViewMode = .formatted

    /// `(folder, uid, seen)` — the folder is part of the identity being reported, not
    /// context: a UID means nothing without it, and the list must be able to tell that this
    /// callback is about a folder it is no longer showing.
    @ObservationIgnored var onSeenChanged: ((String, UInt32, Bool) -> Void)?
    @ObservationIgnored var onRemoved: ((String, UInt32) -> Void)?
    /// A move/delete hit `MailClientError.folderChanged`: the folder's UIDVALIDITY moved
    /// server-side. This view model no longer drops the folder's cache itself — that bare
    /// `Task.detached` raced the list's own queued cache-write chain and could be undone by a
    /// write already in flight (fix round 1, important 2) — it only reports the folder name so
    /// the caller can route the recovery through `MailListViewModel.recoverFromFolderChange(_:)`,
    /// which drops through that same chain.
    @ObservationIgnored var onFolderChanged: ((String) -> Void)?
    @ObservationIgnored private let session: MailPageSession
    @ObservationIgnored private let folderRoles: [MailFolderRole: String]
    @ObservationIgnored private let cache: MailCache
    @ObservationIgnored private let prefs: any MailPreferences
    @ObservationIgnored private let notifier: MailNotifier
    /// The UIDVALIDITY the cached page for this folder was built from, read once in `load()`
    /// and reused by `move`/`delete` — never re-fetched right before a move, which would make
    /// `MailMover`'s own freshness check moot (dispatch addition 3).
    @ObservationIgnored private var pageUIDValidity: UInt32?
    /// Bumped every time `apply`/`loadImages` starts an off-main HTML (re)computation, so a
    /// slower, now-superseded one can't overwrite a result a later call already applied — e.g.
    /// a retry `load()` racing a `loadImages()` tap, either order (fix round 2, minors 2–3).
    @ObservationIgnored private var htmlGeneration = 0

    init(
        route: MailMessageRoute,
        session: MailPageSession,
        folderRoles: [MailFolderRole: String],
        cache: MailCache = MailAccountManager.shared.cache,
        prefs: any MailPreferences = MailAccountManager.shared.prefs,
        notifier: MailNotifier = MailChecker.shared.notifier
    ) {
        self.route = route
        self.session = session
        self.folderRoles = folderRoles
        self.cache = cache
        self.prefs = prefs
        self.notifier = notifier
    }

    /// Delete means "move to 回收筒"; inside 回收筒 (or with no 回收筒) it is permanent (§8.3).
    var deleteIsPermanent: Bool {
        guard let trash = folderRoles[.trash] else { return true }
        return route.folder == trash
    }

    var original: MailOriginal? {
        guard let detail else { return nil }
        let summary = detail.summary
        return MailOriginal(
            // A cached bounce has a name and no address (`MailAddress.parseSender`), and the
            // name is still what a forward's header block and a reply's 「…寫道：」 line
            // should print — so `from` is built whenever either half survives, not only when
            // there is an address. The empty address is what stops `replyRecipients` from
            // turning it into a recipient.
            from: sender(of: summary),
            to: (summary.to ?? []).flatMap(MailAddress.parseList),
            cc: (summary.cc ?? []).flatMap(MailAddress.parseList),
            subject: summary.subject ?? "",
            date: summary.date,
            messageID: detail.messageID,
            references: detail.references ?? [],
            bodyText: plainText
        )
    }

    private func sender(of summary: MailSummary) -> MailAddress? {
        let address = summary.fromAddress?.mailNonEmpty
        let name = summary.fromName?.mailNonEmpty
        guard address != nil || name != nil else { return nil }
        return MailAddress(name: name, address: address ?? "")
    }

    // MARK: Loading

    func load() async {
        let cache = self.cache
        let folder = route.folder
        let uid = route.uid
        let validity = await Task.detached { cache.loadPage(folder: folder)?.uidValidity }.value
        pageUIDValidity = validity
        if detail == nil, let validity {
            let cached = await Task.detached { cache.loadDetail(folder: folder, uidValidity: validity, uid: uid) }.value
            if let cached { await apply(cached) }
        }
        do {
            let fresh = try await session.use { client in try await client.detail(folder: folder, uid: uid) }
            await apply(fresh)
            if let validity {
                await Task.detached { cache.saveDetail(fresh, folder: folder, uidValidity: validity) }.value
            }
            if !fresh.summary.isSeen {
                try await session.use { client in
                    try await client.setFlag(.seen, on: true, folder: folder, uids: [uid], expectedUIDValidity: validity)
                }
                detail?.summary.isSeen = true
                onSeenChanged?(folder, uid, true)
                if folder == MailConstants.inbox, let inboxValidity = prefs.inboxUIDValidity {
                    notifier.removeNotification(uidValidity: inboxValidity, uid: uid)
                }
            }
        } catch MailClientError.folderChanged {
            // Fix round 2, minor 4: the live fetch or the mark-as-seen `setFlag` above can also
            // hit `folderChanged` — the list needs to recover the same way a move/delete would
            // trigger.
            onFolderChanged?(folder)
            if detail == nil {
                loadState = .failed(MailAccountManager.LoginError(MailClientError.folderChanged).message)
            } else {
                actionError = MailAccountManager.LoginError(MailClientError.folderChanged).message
            }
        } catch {
            // A cached detail may already be showing (fix round 1, minor 7): a failed refresh
            // or a failed mark-as-seen must still surface, not be silently swallowed just
            // because there's something on screen already.
            if detail == nil {
                loadState = .failed(MailAccountManager.LoginError(error).message)
            } else {
                actionError = MailAccountManager.LoginError(error).message
            }
        }
    }

    /// Off the main actor, like `apply` (fix round 2, minor 3) — the same SwiftSoup work runs
    /// here (a full re-sanitize plus a link rewrite), so it belongs on the same detached path,
    /// guarded by the same generation token.
    func loadImages() async {
        allowRemoteImages = true
        guard let html = detail?.htmlBody else { return }
        guard let computed = await recomputeSanitizedHTML(html: html, textBody: nil, allowImages: true) else { return }
        sanitized = computed.0
        linkedDocument = computed.1
    }

    /// `BODY.PEEK[]`: never marks the mail read. Asks first above 5 MB.
    func loadSource(confirmed: Bool = false) async {
        if !confirmed, let size = detail?.summary.size, size > MailConstants.sourceConfirmBytes {
            needsSourceConfirmation = true
            return
        }
        needsSourceConfirmation = false
        sourceLoadFailed = false
        do {
            let folder = route.folder
            let uid = route.uid
            let data = try await session.use { client in try await client.rawSource(folder: folder, uid: uid) }
            source = await Task.detached { String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "" }.value
        } catch {
            actionError = MailAccountManager.LoginError(error).message
            sourceLoadFailed = true
        }
    }

    func cancelSource() {
        needsSourceConfirmation = false
        mode = .formatted
    }

    // MARK: Actions

    func toggleSeen() async {
        guard let seen = detail?.summary.isSeen else { return }
        let folder = route.folder
        let uid = route.uid
        do {
            let validity = pageUIDValidity
            try await session.use { client in
                try await client.setFlag(.seen, on: !seen, folder: folder, uids: [uid], expectedUIDValidity: validity)
            }
            detail?.summary.isSeen = !seen
            onSeenChanged?(folder, uid, !seen)
        } catch MailClientError.folderChanged {
            // Fix round 2, minor 4: `setFlag` can hit the same `folderChanged` a move/delete
            // would — the list needs to recover here too, not only from `performMove`.
            actionError = MailAccountManager.LoginError(MailClientError.folderChanged).message
            onFolderChanged?(folder)
        } catch {
            actionError = MailAccountManager.LoginError(error).message
        }
    }

    func move(to target: String) async -> Bool {
        await performMove { client, owned in
            try await MailMover.move(uids: [self.route.uid], from: self.route.folder, to: target, client: client, previouslyFlagged: owned)
        }
    }

    /// The caller confirms first when `deleteIsPermanent`.
    func delete() async -> Bool {
        if !deleteIsPermanent, let trash = folderRoles[.trash] {
            return await move(to: trash)
        }
        return await performMove { client, owned in
            try await MailMover.deletePermanently(uids: [self.route.uid], in: self.route.folder, client: client, previouslyFlagged: owned)
        }
    }

    /// Uses the folder's cached page UIDVALIDITY (read once in `load()`) to build the
    /// owned-deleted set, runs `operation` through the shared page session (dispatch addition
    /// 7), and persists whatever it reports still pending.
    ///
    /// Without a cached page validity there is nothing honest to compare against — fetching one
    /// fresh right here would make `MailMover`'s own freshness check compare a value against
    /// itself, silently defeating it on (for instance) the deep-link-straight-into-a-folder
    /// path. Refuses instead, with the same folder-changed error a real mismatch would show
    /// (fix round 1, minor 8): the user is told to open the folder (from the list) first.
    ///
    /// `MailClientError.folderChanged` reports the folder via `onFolderChanged` rather than
    /// touching the cache itself — see that property's doc (fix round 1, important 2).
    ///
    /// A failure part-way through is not just a failure: COPY and STORE may already have landed,
    /// and a `\Deleted` UID this app flagged but does not claim makes `shouldExpunge` false in
    /// that folder from then on — every later delete there degrades to "hide" and 回收筒 stops
    /// deleting anything. So the `catch` asks the server once, through
    /// `MailMover.recoverAfterFailure`, whether the flag actually took, and persists the claim.
    private func performMove(_ operation: @escaping (any MailClient, OwnedDeleted) async throws -> MailMoveResult) async -> Bool {
        // Move and delete are four to five round trips with no progress indication, so a second
        // tap is expected behaviour. Without this the second COPYs the same mail again — it
        // lands in both 回收筒 and the move target — and both calls read `ownedDeleted` before
        // either writes it back, dropping one call's pending UID and wedging the folder exactly
        // as above. Set before the first `await`, so the two can never both get past it.
        guard !isMoving else { return false }
        let folder = route.folder
        guard let uidValidity = pageUIDValidity else {
            actionError = MailAccountManager.LoginError(MailClientError.folderChanged).message
            return false
        }
        isMoving = true
        defer { isMoving = false }
        let uid = route.uid
        let wasAlreadyDeleted = detail?.summary.isDeleted ?? false
        let owned = prefs.ownedDeleted(folder: folder, uidValidity: uidValidity)
        do {
            let result = try await session.use { client in try await operation(client, owned) }
            prefs.setOwnedDeleted(result.stillPending)
            onRemoved?(folder, uid)
            return true
        } catch {
            // Checked before opening a session, not inside one: after an authentication or
            // certificate rejection even resolving a client is another doomed attempt against a
            // server that already refused.
            if MailMover.shouldProbeAfterFailure(error) {
                let recovered = try? await session.use { client in
                    await MailMover.recoverAfterFailure(after: error, uid: uid, previouslyFlagged: owned,
                                                        client: client, wasAlreadyDeleted: wasAlreadyDeleted)
                }
                if let claim = recovered ?? nil { prefs.setOwnedDeleted(claim) }
            }
            actionError = MailAccountManager.LoginError(error).message
            if (error as? MailClientError) == .folderChanged { onFolderChanged?(folder) }
            return false
        }
    }

    // MARK: Attachments and links

    /// The download and the write are both off the main actor (dispatch addition 6): the
    /// fetch hops to the `MailClient` actor already, and the temp-file write is detached
    /// explicitly since `MailCache` does synchronous disk I/O.
    func prepareAttachment(_ part: MailBodyPart) async -> URL? {
        let folder = route.folder
        let uid = route.uid
        do {
            let data = try await session.use { client in try await client.attachment(folder: folder, uid: uid, part: part) }
            let cache = self.cache
            let filename = MailWarnings.displayFilename(part.filename ?? "attachment")
            return try await Task.detached {
                let url = try cache.temporaryFileURL(filename: filename)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return url
            }.value
        } catch {
            actionError = MailAccountManager.LoginError(error).message
            return nil
        }
    }

    /// Risky, or never rendered in the app — either way, opening OR saving goes through a
    /// warning first (§9.5; dispatch addition 5: confirmation before either, not just open).
    func isRisky(_ part: MailBodyPart) -> Bool {
        let filename = part.filename ?? ""
        let context = (detail?.summary.subject ?? "") + "\n" + plainText
        if MailWarnings.attachmentRisk(filename: filename, contentType: part.contentType, subjectAndBody: context) != nil { return true }
        return isNeverRenderedInApp(part)
    }

    /// HTML/SVG (by extension or by content type) is never rendered in the app at all (§9.5:
    /// 「只能儲存或交給其他 App」) — unlike a merely risky file, "open" must always take the
    /// share-sheet hand-off path regardless of what the user asked for, never Quick Look, which
    /// renders HTML/SVG in-process with WebKit (JavaScript on, remote loads allowed) — exactly
    /// what the locked-down message web view exists to prevent (fix round 1, critical 1).
    func isNeverRenderedInApp(_ part: MailBodyPart) -> Bool {
        let filename = part.filename ?? ""
        if MailWarnings.neverRenderedInApp(filename: filename) { return true }
        // Real parts carry parameters (SwiftMail appends `; charset=…`) — comparing the whole
        // string left this inert against them (fix round 2, critical 1 leftover): an HTML part
        // declaring `text/html; charset=UTF-8` compared equal to neither branch below and went
        // straight to Quick Look uncontested, the exact mislabeled-extension case this predicate
        // exists for. `contentTypeWithoutParameters` is the same helper `attachmentRisk` uses.
        let type = MailWarnings.contentTypeWithoutParameters(part.contentType) ?? ""
        return type == "text/html" || type == "image/svg+xml"
    }

    /// `index` is `n` from a tapped `https://link.invalid/<n>` (the web view range-checks it
    /// itself before calling back), addressing `linkedDocument.links` — the list read off the
    /// very anchors the web view shows, never `sanitized.links`, whose indices a second HTML
    /// parse could shift (dispatch addition 1). `nil` for an index with no link.
    func linkTarget(forIndex index: Int) -> MailLinkTarget? {
        guard let links = linkedDocument?.links, links.indices.contains(index) else { return nil }
        let link = links[index]
        return Self.target(text: link.text, href: link.href)
    }

    /// For a link found only in the plain-text fallback view (`MailTextLinkifier`, shown when
    /// there is no HTML body): no second HTML parse sits between what the user tapped and this
    /// call, so the literal URL is judged, shown and opened directly.
    func linkTarget(forPlainText url: URL) -> MailLinkTarget {
        Self.target(text: url.absoluteString, href: url.absoluteString)
    }

    private static func target(text: String, href rawHref: String) -> MailLinkTarget {
        let trimmed = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let canonical = MailWarnings.canonicalHref(trimmed) else {
            return MailLinkTarget(href: MailTextCleaner.clean(trimmed), issues: [], canOpen: false)
        }
        return MailLinkTarget(
            href: MailTextCleaner.clean(canonical),
            issues: MailWarnings.linkIssues(text: text, href: canonical),
            canOpen: true
        )
    }

    // MARK: Internals

    /// `MailHTMLSanitizer.sanitize` + `.rewriteLinks` together run SwiftSoup's parser up to
    /// three times (a parse, a rewrite-and-reserialize, and the rewrite's own reparse for its
    /// lockstep check); doing that inline here would block the main actor on a large or complex
    /// mail. Computed inside a detached task instead (fix round 1, minor 9).
    ///
    /// Bumps and captures `htmlGeneration` before the detached work starts, and only returns a
    /// result (instead of `nil`) if that generation is still the current one once the work
    /// finishes — so whichever of `apply`/`loadImages` started *last* is the only one whose
    /// result a caller ever applies, regardless of completion order (fix round 2, minors 2–3).
    private func recomputeSanitizedHTML(html: String?, textBody: String?, allowImages: Bool) async -> (SanitizedHTML?, LinkedHTML?, String)? {
        htmlGeneration += 1
        let generation = htmlGeneration
        let computed = await Task.detached { () -> (SanitizedHTML?, LinkedHTML?, String) in
            guard let html else { return (nil, nil, textBody ?? "") }
            let sanitized = MailHTMLSanitizer.sanitize(html, allowRemoteImages: allowImages)
            let linked = MailHTMLSanitizer.rewriteLinks(sanitized.html)
            // The *sanitized* document, matching Android's
            // `SchoolMailMessageViewModel` — never the raw body. Text the sanitizer drops
            // with its container (`<noscript>`, `<form>`, `<script>`) is invisible in the
            // formatted view, so building the plain view from the raw html would show it
            // (and linkify URLs inside it) only in the plain view: two views of one mail
            // saying different things, which is exactly the bait-and-switch shape the
            // warning layer exists to catch. It also feeds the password-bait keyword
            // haystack, which would otherwise fire on text the user is never shown.
            let plain = textBody ?? MailHTMLSanitizer.plainText(fromHTML: sanitized.html)
            return (sanitized, linked, plain)
        }.value
        return generation == htmlGeneration ? computed : nil
    }

    private func apply(_ detail: MailMessageDetail) async {
        guard let computed = await recomputeSanitizedHTML(html: detail.htmlBody, textBody: detail.textBody, allowImages: allowRemoteImages) else {
            return
        }
        self.detail = detail
        let (freshSanitized, freshLinked, freshPlainText) = computed
        sanitized = freshSanitized
        linkedDocument = freshLinked
        plainText = freshPlainText
        parseFailed = detail.textBody == nil && detail.htmlBody == nil && detail.attachments.isEmpty
        if parseFailed { mode = .source }
        let summary = detail.summary
        warnings = MailWarnings.evaluate(MailWarningInput(
            fromAddress: summary.fromAddress ?? "",
            fromName: summary.fromName,
            subject: summary.subject ?? "",
            plainText: plainText,
            links: freshSanitized?.links ?? [],
            attachments: detail.attachments.map { MailAttachmentInfo(filename: $0.filename ?? "", contentType: $0.contentType) }
        ))
        loadState = .loaded
    }
}
#endif
