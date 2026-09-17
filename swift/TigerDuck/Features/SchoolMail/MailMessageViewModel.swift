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
    private(set) var allowRemoteImages = false
    private(set) var actionError: String?
    var mode: ViewMode = .formatted

    @ObservationIgnored var onSeenChanged: ((UInt32, Bool) -> Void)?
    @ObservationIgnored var onRemoved: ((UInt32) -> Void)?
    @ObservationIgnored private let session: MailPageSession
    @ObservationIgnored private let folderRoles: [MailFolderRole: String]
    @ObservationIgnored private let cache: MailCache
    @ObservationIgnored private let prefs: any MailPreferences
    @ObservationIgnored private let notifier: MailNotifier
    /// The UIDVALIDITY the cached page for this folder was built from, read once in `load()`
    /// and reused by `move`/`delete` — never re-fetched right before a move, which would make
    /// `MailMover`'s own freshness check moot (dispatch addition 3).
    @ObservationIgnored private var pageUIDValidity: UInt32?

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
            from: summary.fromAddress.map { MailAddress(name: summary.fromName, address: $0) },
            to: (summary.to ?? []).flatMap(MailAddress.parseList),
            cc: (summary.cc ?? []).flatMap(MailAddress.parseList),
            subject: summary.subject ?? "",
            date: summary.date,
            messageID: detail.messageID,
            references: detail.references ?? [],
            bodyText: plainText
        )
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
            if let cached { apply(cached) }
        }
        do {
            let fresh = try await session.use { client in try await client.detail(folder: folder, uid: uid) }
            apply(fresh)
            if let validity {
                await Task.detached { cache.saveDetail(fresh, folder: folder, uidValidity: validity) }.value
            }
            if !fresh.summary.isSeen {
                try await session.use { client in try await client.setFlag(.seen, on: true, folder: folder, uids: [uid]) }
                detail?.summary.isSeen = true
                onSeenChanged?(uid, true)
                if folder == MailConstants.inbox, let inboxValidity = prefs.inboxUIDValidity {
                    notifier.removeNotification(uidValidity: inboxValidity, uid: uid)
                }
            }
        } catch {
            if detail == nil { loadState = .failed(MailAccountManager.LoginError(error).message) }
        }
    }

    func loadImages() {
        allowRemoteImages = true
        guard let html = detail?.htmlBody else { return }
        let fresh = MailHTMLSanitizer.sanitize(html, allowRemoteImages: true)
        sanitized = fresh
        linkedDocument = MailHTMLSanitizer.rewriteLinks(fresh.html)
    }

    /// `BODY.PEEK[]`: never marks the mail read. Asks first above 5 MB.
    func loadSource(confirmed: Bool = false) async {
        if !confirmed, let size = detail?.summary.size, size > MailConstants.sourceConfirmBytes {
            needsSourceConfirmation = true
            return
        }
        needsSourceConfirmation = false
        do {
            let folder = route.folder
            let uid = route.uid
            let data = try await session.use { client in try await client.rawSource(folder: folder, uid: uid) }
            source = await Task.detached { String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "" }.value
        } catch {
            actionError = MailAccountManager.LoginError(error).message
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
            try await session.use { client in try await client.setFlag(.seen, on: !seen, folder: folder, uids: [uid]) }
            detail?.summary.isSeen = !seen
            onSeenChanged?(uid, !seen)
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

    /// Resolves the folder's current UIDVALIDITY (the cached page's, read in `load()`, falling
    /// back to a fresh `STATUS` only when nothing was cached), builds the owned-deleted set for
    /// it, runs `operation` through the shared page session (dispatch addition 7), and persists
    /// whatever it reports still pending. `MailClientError.folderChanged` also drops this
    /// folder's cache (dispatch addition 4) so a later list load never serves a stale page.
    private func performMove(_ operation: @escaping (any MailClient, OwnedDeleted) async throws -> MailMoveResult) async -> Bool {
        let folder = route.folder
        do {
            let uidValidity = try await currentUIDValidity()
            let owned = prefs.ownedDeleted(folder: folder, uidValidity: uidValidity)
            let result = try await session.use { client in try await operation(client, owned) }
            prefs.setOwnedDeleted(result.stillPending)
            onRemoved?(route.uid)
            return true
        } catch MailClientError.folderChanged {
            actionError = MailAccountManager.LoginError(MailClientError.folderChanged).message
            let cache = self.cache
            await Task.detached { cache.dropFolder(folder) }.value
            return false
        } catch {
            actionError = MailAccountManager.LoginError(error).message
            return false
        }
    }

    private func currentUIDValidity() async throws -> UInt32 {
        if let pageUIDValidity { return pageUIDValidity }
        let folder = route.folder
        return try await session.use { client in try await client.status(folder: folder).uidValidity }
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

    /// Risky, or HTML/SVG — never rendered in the app; opening OR saving goes through a
    /// warning first (§9.5; dispatch addition 5: confirmation before either, not just open).
    func isRisky(_ part: MailBodyPart) -> Bool {
        let filename = part.filename ?? ""
        let context = (detail?.summary.subject ?? "") + "\n" + plainText
        if MailWarnings.attachmentRisk(filename: filename, contentType: part.contentType, subjectAndBody: context) != nil { return true }
        if MailWarnings.neverRenderedInApp(filename: filename) { return true }
        let type = (part.contentType).lowercased()
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

    private func apply(_ detail: MailMessageDetail) {
        self.detail = detail
        let freshSanitized = detail.htmlBody.map { MailHTMLSanitizer.sanitize($0, allowRemoteImages: allowRemoteImages) }
        sanitized = freshSanitized
        linkedDocument = freshSanitized.map { MailHTMLSanitizer.rewriteLinks($0.html) }
        plainText = detail.textBody ?? detail.htmlBody.map(MailHTMLSanitizer.plainText(fromHTML:)) ?? ""
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
