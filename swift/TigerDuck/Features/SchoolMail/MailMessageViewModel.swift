#if os(iOS)
import Foundation
import Observation

struct MailMessageRoute: Hashable {
    var folder: String
    var uid: UInt32
    /// The generation `uid` belongs to, when the route knows it — a notification does, and the
    /// folder can be recreated between the post and the tap. `nil` defers to the cached page's.
    var uidValidity: UInt32? = nil
}

/// One tapped link, judged, shown and opened as the same canonicalized string. `canOpen` is
/// false for an http(s) href a browser-style parse rejects, and for any scheme outside
/// `openableSchemes`; the dialog then still shows the href (bidi-stripped) but without an Open
/// action. `id` is the href itself: this value only ever backs one transient confirmation sheet
/// at a time, never a list, so a repeated href across separate taps is not a problem.
nonisolated struct MailLinkTarget: Equatable, Sendable, Identifiable {
    var href: String
    var issues: [MailLinkIssue]
    var canOpen: Bool
    var id: String { href }

    /// The only schemes a link in a mail may be opened with.
    ///
    /// `MailWarnings.canonicalHref` canonicalizes `http`/`https` and returns any other scheme
    /// unchanged, judging nothing else, so without this set every scheme would be openable. The
    /// sanitizer's `addProtocols("a", "href", "http", "https", "mailto")` closes the HTML path,
    /// but in plain text a link is whatever `NSDataDetector` finds. `InAppBrowserView` refuses
    /// non-http(s); the `openURL(url)` branch would hand the system any scheme, `tigerduck://`
    /// included, so a mail could drive the app's own deep links with one confirmed tap.
    static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    /// Whether `href` names a scheme this app will open. A relative or scheme-less href is not
    /// openable: there is no base URL a mail's link could be resolved against.
    static func isOpenable(_ href: String) -> Bool {
        guard let scheme = scheme(of: href) else { return false }
        return openableSchemes.contains(scheme)
    }

    /// The scheme, lower-cased, per RFC 3986 §3.1 (`ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`),
    /// or nil when there is none. The character rule is also what keeps a colon *inside* a path
    /// or a userinfo from being read as a scheme separator.
    private static func scheme(of href: String) -> String? {
        let href = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = href.firstIndex(of: ":") else { return nil }
        let scheme = href[href.startIndex..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter else { return nil }
        let isSchemeCharacter = { (character: Character) in
            character.isASCII && (character.isLetter || character.isNumber || "+-.".contains(character))
        }
        guard scheme.allSatisfy(isSchemeCharacter) else { return nil }
        return scheme.lowercased()
    }
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
    /// This mail's row as the folder's cached page has it, read in `load()` before the body is
    /// asked for. The list page is on disk long before the (much slower) body fetch returns, so
    /// the sender, subject and date are knowable straight away even when no body has ever been
    /// cached — see `summary`.
    private(set) var cachedSummary: MailSummary?
    private(set) var loadState: LoadState = .loading
    private(set) var sanitized: SanitizedHTML?
    /// `sanitized.html`, with every `<a href>` rewritten to an index into `linkedDocument.links`
    /// — what the web view actually loads. See `linkTarget(forIndex:)`.
    private(set) var linkedDocument: LinkedHTML?
    private(set) var plainText = ""
    private(set) var warnings: [MailWarning] = []
    /// Nothing this screen can render: no text body, no HTML body, no attachments. Drives the
    /// "Couldn't read this mail's format. Showing its source instead." banner and the forced
    /// source view below. It says what there is to show, not why: `LiveMailClient` parses the
    /// MIME itself when Mail2000 gets a `BODYSTRUCTURE` wrong, so such a mail opens normally.
    /// What is left is a mail that carries nothing, and one with an unusable structure that is
    /// too large to download whole for a local parse (`MailConstants.maxLocalParseBytes`). Both
    /// leave only the raw source, so they read the same banner.
    private(set) var parseFailed = false
    private(set) var source: String?
    /// Set when `loadSource` throws, cleared at the start of the next attempt. Lets the source
    /// view show a retryable failed state instead of spinning forever.
    private(set) var sourceLoadFailed = false
    private(set) var allowRemoteImages = false
    private(set) var actionError: String?
    /// True for the whole of a move or delete — four to five IMAP round trips with nothing on
    /// screen to say so — and for the `prepareDelete()` that may precede one. The view disables
    /// every affordance that starts one while it is set; `performMove` refuses as well, so a tap
    /// the view somehow lets through still cannot file the same mail into two folders.
    private(set) var isMoving = false
    /// The account's role folders, as the list resolved them when this screen opened — and as
    /// `prepareDelete()` re-resolves them after creating a missing Trash. Observed (not
    /// `@ObservationIgnored`) precisely because it changes: `deleteIsPermanent` and the move
    /// sheet are both read off it, and both have to follow a folder that has just come into
    /// existence.
    private(set) var folderRoles: [MailFolderRole: String]
    var mode: ViewMode = .formatted
    /// "View in light mode": the formatted view drawn on white paper (`MailHTMLTheme.light`)
    /// instead of the app's own page. It belongs to this screen, like `mode` — never saved — so
    /// the next mail opens on the app's page again; only the mail that needed it was switched.
    var viewsInLightMode = false

    /// `(folder, uid, seen)` — the folder is part of the identity being reported, not
    /// context: a UID means nothing without it, and the list must be able to tell that this
    /// callback is about a folder it is no longer showing.
    @ObservationIgnored var onSeenChanged: ((String, UInt32, Bool) -> Void)?
    @ObservationIgnored var onRemoved: ((String, UInt32) -> Void)?
    /// A move/delete hit `MailClientError.folderChanged`: the folder's UIDVALIDITY changed
    /// server-side. This view model does not drop the folder's cache itself, since a bare
    /// `Task.detached` would race the list's queued cache-write chain and could be undone by a
    /// write already in flight. It reports the folder name, and the caller recovers through
    /// `MailListViewModel.recoverFromFolderChange(_:)`, which drops it through that same chain.
    @ObservationIgnored var onFolderChanged: ((String) -> Void)?
    /// `prepareDelete()` created a missing role folder and re-resolved the map: the list holds
    /// its own copy, resolved once per session, and would otherwise keep handing every later
    /// screen a map that still says the folder does not exist.
    @ObservationIgnored var onFolderRolesChanged: (([MailFolderRole: String]) -> Void)?
    @ObservationIgnored private let session: MailPageSession
    @ObservationIgnored private let cache: MailCache
    @ObservationIgnored private let prefs: any MailPreferences
    @ObservationIgnored private let notifier: MailNotifier
    /// The UIDVALIDITY the cached page for this folder was built from, read once in `load()`
    /// and reused by `move`/`delete`. Never re-fetched right before a move: that would make
    /// `MailMover`'s own freshness check moot.
    @ObservationIgnored private var pageUIDValidity: UInt32?
    /// Bumped every time `apply`/`loadImages` starts an off-main HTML (re)computation, so a
    /// slower, superseded one can't overwrite a result a later call already applied, such as a
    /// retry `load()` racing a `loadImages()` tap, in either order.
    @ObservationIgnored private var htmlGeneration = 0

    /// `cache` and `prefs` are injectable only so a test can use throwaway storage instead of
    /// the app's real singleton, which reaches the real `UserDefaults` and cache directory.
    ///
    /// Both default to `nil` rather than `= MailAccountManager.shared.…`: a default argument
    /// expression is type-checked in a nonisolated context, and `MailAccountManager.shared` is
    /// main-actor isolated, so naming it there is an isolation violation in the Swift 6
    /// language mode. Resolving them in this main-actor body keeps the seam the same: a passed
    /// value is used, and an omitted one gets the singleton's.
    init(
        route: MailMessageRoute,
        session: MailPageSession,
        folderRoles: [MailFolderRole: String],
        cache: MailCache? = nil,
        prefs: (any MailPreferences)? = nil,
        notifier: MailNotifier = MailChecker.shared.notifier
    ) {
        self.route = route
        self.session = session
        self.folderRoles = folderRoles
        self.cache = cache ?? MailAccountManager.shared.cache
        self.prefs = prefs ?? MailAccountManager.shared.prefs
        self.notifier = notifier
    }

    /// What the header should show. The body is the slow half of opening a mail — a fetch, a
    /// parse and a sanitize — while the sender, subject and date are already in the folder page
    /// the list cached, so the screen has no reason to withhold the whole header behind a
    /// spinner until the body lands. Prefers the loaded message, since a summary can have been
    /// refreshed by the fetch.
    var summary: MailSummary? { detail?.summary ?? cachedSummary }

    /// The modes worth offering for this mail. The formatted view renders the sanitized HTML
    /// document, so a mail that carries no HTML part has nothing to show there — Android hides
    /// the mode outright rather than letting the user pick a view that renders nothing, and so
    /// do we. Until a message has loaded the answer is not known yet, so all three stay on
    /// offer; `apply` moves the selection off the formatted view at the moment a mail turns out
    /// to be plain-text only, so the picker is never left selecting a mode that has just
    /// disappeared.
    var availableModes: [ViewMode] {
        guard detail != nil else { return ViewMode.allCases }
        return linkedDocument == nil ? [.plain, .source] : ViewMode.allCases
    }

    /// Whether the menu offers "View in light mode". Only the formatted view of an HTML mail is
    /// drawn on a page at all — plain text and source are the app's own text — so anywhere else
    /// the item would change nothing on screen.
    var offersLightMode: Bool { mode == .formatted && linkedDocument != nil }

    /// The page the formatted view draws the mail on.
    var htmlTheme: MailHTMLTheme { viewsInLightMode ? .light : .app }

    /// Delete means "move to Trash"; inside Trash, or with no Trash folder resolved, it is
    /// permanent.
    ///
    /// `true` for an account with no Trash: this says what the delete the user is about to
    /// confirm will do, and until a Trash folder exists that is a permanent delete.
    /// `prepareDelete()` creates one and runs before either confirmation is raised, so this is
    /// read after any creation has already succeeded or failed, never in the hope that one will.
    var deleteIsPermanent: Bool {
        guard let trash = folderRoles[.trash] else { return true }
        return route.folder == trash
    }

    var original: MailOriginal? {
        guard let detail else { return nil }
        let summary = detail.summary
        return MailOriginal(
            // A cached bounce has a name and no address (`MailAddress.parseSender`). A forward's
            // header and a reply's "… wrote:" line still print the name, so `from` is built when
            // either half survives. The empty address keeps it out of `replyRecipients`.
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
        let account = prefs.studentID
        let cachedPage = await Task.detached { cache.loadPage(folder: folder) }.value
        // Pins to the route's generation when it names one, and ignores a page from any other:
        // after a folder recreation the same UID is another mail, which the pinned fetch refuses
        // with `folderChanged` instead of opening it and marking it read.
        let validity = route.uidValidity ?? cachedPage?.uidValidity
        let page = cachedPage?.uidValidity == validity ? cachedPage : nil
        pageUIDValidity = validity
        if detail == nil {
            // The header can be drawn from this alone, so it goes up before the body is even
            // asked for rather than after — the row is already on disk, the body may be seconds
            // away or may fail outright.
            cachedSummary = page?.summaries.first { $0.uid == uid }
        }
        if detail == nil, let validity {
            let cached = await Task.detached { cache.loadDetail(folder: folder, uidValidity: validity, uid: uid) }.value
            if let cached { await apply(cached) }
        }
        do {
            // Pinned to the generation `move`/`delete`/`toggleSeen` use. After a server-side folder
            // recreation this UID can name another message, which would render here and be cached
            // under the old generation's key. The `setFlag` below is pinned but skips read mail.
            let fresh = try await session.use { client in
                try await client.detail(folder: folder, uid: uid, expectedUIDValidity: validity)
            }
            await apply(fresh)
            // The cache stamps whoever is signed in when it writes: a body fetched for a student
            // who signed out while it was on the wire must not be filed under the next one.
            if let validity, prefs.studentID == account {
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
            // The live fetch or the mark-as-seen `setFlag` above can hit `folderChanged` too, and
            // the list has to recover the same way as after a move or delete.
            onFolderChanged?(folder)
            if detail == nil {
                loadState = .failed(MailAccountManager.LoginError(MailClientError.folderChanged).message)
            } else {
                actionError = MailAccountManager.LoginError(MailClientError.folderChanged).message
            }
        } catch {
            // A cached detail may already be showing. A failed refresh or mark-as-seen must still
            // surface, not be swallowed because something is on screen.
            if detail == nil {
                loadState = .failed(MailAccountManager.LoginError(error).message)
            } else {
                actionError = MailAccountManager.LoginError(error).message
            }
        }
    }

    /// Off the main actor, like `apply`: the same SwiftSoup work runs here (a full re-sanitize
    /// plus a link rewrite), so it takes the same detached path, guarded by the same generation
    /// token.
    func loadImages() async {
        allowRemoteImages = true
        guard let html = detail?.htmlBody else { return }
        guard let computed = await recomputeSanitizedHTML(html: html, textBody: nil, allowImages: true) else { return }
        sanitized = computed.0
        linkedDocument = computed.1
    }

    /// `BODY.PEEK[]`: never marks the mail read. No size prompt: `MailSourceTextView` lays out
    /// only the visible viewport, so a multi-megabyte source costs a download, not a frozen
    /// screen.
    ///
    /// Cache-first like the body in `load()` and keyed the same way (folder, this folder's
    /// cached-page UIDVALIDITY, UID), in the same directory and LRU budget, so a visit does not
    /// download the whole source again. Without a cached page there is no UIDVALIDITY to key
    /// by, so the fetch still works but is not saved, the same rule `load()` applies to a body.
    func loadSource() async {
        sourceLoadFailed = false
        let cache = self.cache
        let folder = route.folder
        let uid = route.uid
        let validity = pageUIDValidity
        let account = prefs.studentID
        if let validity,
           let cached = await Task.detached(operation: { cache.loadSource(folder: folder, uidValidity: validity, uid: uid) }).value {
            source = cached
            return
        }
        do {
            let data = try await session.use { client in try await client.rawSource(folder: folder, uid: uid) }
            let text = await Task.detached { String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "" }.value
            source = text
            // As in `load()`: never filed under a student other than the one it was fetched for.
            if let validity, prefs.studentID == account {
                await Task.detached { cache.saveSource(text, folder: folder, uidValidity: validity, uid: uid) }.value
            }
        } catch {
            actionError = MailAccountManager.LoginError(error).message
            sourceLoadFailed = true
        }
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
            // `setFlag` can hit the same `folderChanged` a move or delete would, and the list has
            // to recover here too, not only from `performMove`.
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

    /// Run when Delete is tapped, before either confirmation is raised. Creates a Trash folder if
    /// the account has none and returns the resulting `deleteIsPermanent`, which picks the
    /// dialog: one says the mail will be destroyed, the other that it moves to Trash. Creating
    /// the folder after the user answered would confirm a destruction that does not happen, and
    /// the permanent-delete dialog, the last guard before unrecoverable mail, must mean what it
    /// says. Nothing is created until the user asks to delete, and a cancel costs an empty Trash.
    /// A failed CREATE leaves `deleteIsPermanent` true, so the permanent-delete dialog shows.
    /// This never deletes anything, and `delete()` only runs from behind one of the two dialogs.
    func prepareDelete() async -> Bool {
        guard folderRoles[.trash] == nil, !isMoving else { return deleteIsPermanent }
        isMoving = true
        defer { isMoving = false }
        await ensureFolder(.trash)
        return deleteIsPermanent
    }

    /// The caller confirms first — `prepareDelete()` says which of the two confirmations applies.
    /// Never creates a folder itself: by the time this runs the user has already answered a
    /// dialog whose wording depends on the answer, so changing it here would change what they
    /// agreed to.
    func delete() async -> Bool {
        if !deleteIsPermanent, let trash = folderRoles[.trash] {
            return await move(to: trash)
        }
        return await performMove { client, owned in
            try await MailMover.deletePermanently(uids: [self.route.uid], in: self.route.folder, client: client, previouslyFlagged: owned)
        }
    }

    /// Creates `role`'s folder if the account has none, adopting the role map the provisioner
    /// re-resolved from a fresh folder list. Silent on failure by design: every caller has its
    /// own fallback, and none of them may fail an action the user asked for because a folder
    /// could not be made. `folderRoles` is read into a local first so the `use(_:)` body has no
    /// reason to capture `self`.
    private func ensureFolder(_ role: MailFolderRole) async {
        let known = folderRoles
        let ensured = try? await session.use { client in
            await MailFolderProvisioner.ensure(role, in: known, client: client)
        }
        guard let ensured = ensured ?? nil else { return }
        adoptFolderRoles(ensured.roles)
    }

    /// Takes on a role map re-resolved from a fresh folder list — this screen's own
    /// `ensureFolder`, or the compose sheet it presents having created one — and passes it up to
    /// the list, which resolved its copy once and would otherwise never hear about the folder.
    func adoptFolderRoles(_ roles: [MailFolderRole: String]) {
        guard roles != folderRoles else { return }
        folderRoles = roles
        onFolderRolesChanged?(roles)
    }

    /// A reply or forward sent from this screen went out, but its copy did not reach Sent. The
    /// send itself succeeded, so this is a notice and not a failure — it rides the same
    /// `actionError` banner a failed move or delete uses, which is the one place on this screen
    /// that says "that didn't go the way you'd expect" without taking the mail off screen.
    func reportSentCopyNotice(_ message: String) {
        actionError = message
    }

    /// Builds the owned-deleted set from the folder's cached-page UIDVALIDITY (read once in
    /// `load()`), runs `operation` through the shared page session, and persists whatever it
    /// reports still pending. With no cached validity it refuses with the folder-changed error:
    /// a fresh fetch here would make `MailMover`'s freshness check compare a value with itself.
    /// On `folderChanged` it calls `onFolderChanged` and leaves the cache alone. A failure
    /// part-way may leave a `\Deleted` flag of ours unclaimed, which keeps `shouldExpunge` false
    /// in that folder for good, so the `catch` asks the server once, through
    /// `MailMover.recoverAfterFailure`, whether the flag took, and persists the claim.
    private func performMove(_ operation: @escaping (any MailClient, OwnedDeleted) async throws -> MailMoveResult) async -> Bool {
        // Four or five round trips with no progress shown, so a second tap is expected: it would
        // COPY the mail again, and both calls would read `ownedDeleted` before either writes back,
        // wedging the folder. `isMoving` is set before the first `await`, so only one gets past.
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

    /// The download and the write both run off the main actor: the fetch hops to the
    /// `MailClient` actor already, and the temp-file write is detached since `MailCache` does
    /// synchronous disk I/O.
    func prepareAttachment(_ part: MailBodyPart) async -> URL? {
        let folder = route.folder
        let uid = route.uid
        // The same pin `load()` fetched `part` under. Without it, after a server-side folder
        // recreation the download returns another message's bytes, which go to Quick Look or the
        // share sheet under the filename on screen: the wrong mail would leave the app entirely.
        let validity = pageUIDValidity
        do {
            let data = try await session.use { client in
                try await client.attachment(folder: folder, uid: uid, part: part, expectedUIDValidity: validity)
            }
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

    /// Risky, or never rendered in the app. Either way, opening and saving both go through a
    /// warning first, not only opening.
    func isRisky(_ part: MailBodyPart) -> Bool {
        let filename = part.filename ?? ""
        let context = (detail?.summary.subject ?? "") + "\n" + plainText
        if MailWarnings.attachmentRisk(filename: filename, contentType: part.contentType, subjectAndBody: context) != nil { return true }
        return isNeverRenderedInApp(part)
    }

    /// HTML/SVG (by extension or by content type) is never rendered in the app, only saved or
    /// handed to another app. Unlike a merely risky file, "open" always takes the share-sheet
    /// hand-off, whatever the user asked for, never Quick Look: Quick Look renders HTML/SVG
    /// in-process with WebKit (JavaScript on, remote loads allowed), which is what the
    /// locked-down message web view exists to prevent.
    func isNeverRenderedInApp(_ part: MailBodyPart) -> Bool {
        let filename = part.filename ?? ""
        if MailWarnings.neverRenderedInApp(filename: filename) { return true }
        // Real parts carry parameters (SwiftMail appends `; charset=…`), and a whole-string match
        // would send `text/html; charset=UTF-8` to Quick Look, the mislabeled-extension case this
        // exists for. `contentTypeWithoutParameters` is the same helper `attachmentRisk` uses.
        let type = MailWarnings.contentTypeWithoutParameters(part.contentType) ?? ""
        return type == "text/html" || type == "image/svg+xml"
    }

    /// `index` is `n` from a tapped `https://link.invalid/<n>` (the web view range-checks it
    /// itself before calling back). It addresses `linkedDocument.links`, the list read off the
    /// anchors the web view shows, never `sanitized.links`, whose indices a second HTML parse
    /// could shift. `nil` for an index with no link.
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
            canOpen: MailLinkTarget.isOpenable(canonical)
        )
    }

    // MARK: Internals

    /// `MailHTMLSanitizer.sanitize` and `.rewriteLinks` together run SwiftSoup's parser up to
    /// three times (a parse, a rewrite-and-reserialize, and the rewrite's own reparse for its
    /// lockstep check). Inline, that would block the main actor on a large or complex mail, so
    /// it runs in a detached task.
    ///
    /// Bumps and captures `htmlGeneration` before the work starts and returns `nil` unless it is
    /// still current when the work finishes, so only the last-started of `apply`/`loadImages`
    /// has its result applied, whatever the completion order.
    private func recomputeSanitizedHTML(html: String?, textBody: String?, allowImages: Bool) async -> (SanitizedHTML?, LinkedHTML?, String)? {
        htmlGeneration += 1
        let generation = htmlGeneration
        let computed = await Task.detached { () -> (SanitizedHTML?, LinkedHTML?, String) in
            guard let html else { return (nil, nil, textBody ?? "") }
            let sanitized = MailHTMLSanitizer.sanitize(html, allowRemoteImages: allowImages)
            let linked = MailHTMLSanitizer.rewriteLinks(sanitized.html)
            // Built from the sanitized document, like Android's `SchoolMailMessageViewModel`. From
            // the raw body, text dropped with its container would show only in the plain view,
            // linkified (a bait-and-switch), and fire the password-bait check on text never shown.
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
        // The formatted view is about to stop being offered for a mail with no HTML part
        // (`availableModes`), so a selection resting on it has to move now rather than leave the
        // picker pointing at an entry that is no longer in the menu.
        if freshLinked == nil, mode == .formatted { mode = .plain }
        parseFailed = detail.textBody == nil && detail.htmlBody == nil && detail.attachments.isEmpty
        if parseFailed { mode = .source }
        let summary = detail.summary
        warnings = MailWarnings.evaluate(MailWarningInput(
            fromAddress: summary.fromAddress ?? "",
            fromName: summary.fromName,
            subject: summary.subject ?? "",
            plainText: plainText,
            links: freshSanitized?.links ?? [],
            attachments: detail.attachments.map { MailAttachmentInfo(filename: $0.filename ?? "", contentType: $0.contentType) },
            // Only the opened message has this — the folder list fetches ENVELOPE alone. See
            // `MailWarnings.isBounce` for why the two sites read different signals.
            returnPath: detail.returnPath
        ))
        loadState = .loaded
    }
}
#endif
