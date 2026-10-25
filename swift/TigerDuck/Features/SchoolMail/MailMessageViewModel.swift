#if os(iOS)
import Foundation
import Observation

struct MailMessageRoute: Hashable {
    var folder: String
    var uid: UInt32
    var uidValidity: UInt32? = nil
}

nonisolated struct MailLinkTarget: Equatable, Sendable, Identifiable {
    var href: String
    var issues: [MailLinkIssue]
    var canOpen: Bool
    var id: String { href }

    ///
    static let openableSchemes: Set<String> = ["http", "https", "mailto"]

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

nonisolated struct MailFormattedPages: Equatable, Sendable {
    var app: String
    var light: String
    var setsColors: Bool
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
    private(set) var cachedSummary: MailSummary?
    private(set) var loadState: LoadState = .loading
    private(set) var sanitized: SanitizedHTML?
    private(set) var linkedDocument: LinkedHTML?
    private(set) var pages: MailFormattedPages?
    private(set) var plainText = ""
    private(set) var linkedPlainText = AttributedString()
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
    private(set) var sourceLoadFailed = false
    private(set) var allowRemoteImages = false
    private(set) var actionError: String?
    private(set) var isMoving = false
    private(set) var downloading: Set<String> = []
    private(set) var folderRoles: [MailFolderRole: String]
    var mode: ViewMode = .formatted
    var viewsInLightMode = false
    /// The light appearance draws every mail on the light page, so it offers no other.
    var appearsLight = false
    @ObservationIgnored private var hasPickedPage = false

    @ObservationIgnored var onSeenChanged: ((String, UInt32, Bool) -> Void)?
    @ObservationIgnored var onRemoved: ((String, UInt32) -> Void)?
    @ObservationIgnored var onFolderChanged: ((String) -> Void)?
    @ObservationIgnored var onFolderRolesChanged: (([MailFolderRole: String]) -> Void)?
    @ObservationIgnored private let session: MailPageSession
    @ObservationIgnored private let cache: MailCache
    @ObservationIgnored private let prefs: any MailPreferences
    @ObservationIgnored private let notifier: MailNotifier
    @ObservationIgnored private var pageUIDValidity: UInt32?
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

    var summary: MailSummary? { detail?.summary ?? cachedSummary }

    var availableModes: [ViewMode] {
        guard detail != nil else { return ViewMode.allCases }
        return linkedDocument == nil ? [.plain, .source] : ViewMode.allCases
    }

    var offersLightMode: Bool { !appearsLight && mode == .formatted && linkedDocument != nil }

    var htmlTheme: MailHTMLTheme { showsLightPage ? .light : .app }

    var formattedHTML: String? { showsLightPage ? pages?.light : pages?.app }

    private var showsLightPage: Bool { appearsLight || viewsInLightMode }

    var deleteIsPermanent: Bool {
        guard let trash = folderRoles[.trash] else { return true }
        return route.folder == trash
    }

    var original: MailOriginal? {
        guard let detail else { return nil }
        let summary = detail.summary
        return MailOriginal(
            from: sender(of: summary),
            to: (summary.to ?? []).flatMap(MailAddress.parseList),
            cc: (summary.cc ?? []).flatMap(MailAddress.parseList),
            subject: summary.subject ?? "",
            date: summary.date,
            messageID: detail.messageID,
            references: detail.references ?? [],
            bodyText: plainText,
            replyTo: detail.replyTo.map(MailAddress.parseList)
        )
    }

    private func sender(of summary: MailSummary) -> MailAddress? {
        let address = summary.fromAddress?.mailNonEmpty
        let name = summary.fromName?.mailNonEmpty
        guard address != nil || name != nil else { return nil }
        return MailAddress(name: name, address: address ?? "")
    }

    func load() async {
        let cache = self.cache
        let folder = route.folder
        let uid = route.uid
        let account = prefs.studentID
        let wipeCount = cache.wipeCount
        let cachedPage = await Task.detached { cache.loadPage(folder: folder) }.value
        let validity = route.uidValidity ?? cachedPage?.uidValidity
        let page = cachedPage?.uidValidity == validity ? cachedPage : nil
        pageUIDValidity = validity
        if detail == nil {
            cachedSummary = page?.summaries.first { $0.uid == uid }
        }
        if detail == nil, let validity {
            let cached = await Task.detached { cache.loadDetail(folder: folder, uidValidity: validity, uid: uid) }.value
            if let cached { await apply(cached) }
        }
        do {
            let fresh = try await session.use { client in
                try await client.detail(folder: folder, uid: uid, expectedUIDValidity: validity)
            }
            await apply(fresh)
            if let validity, prefs.studentID == account {
                await Task.detached { cache.saveDetail(fresh, folder: folder, uidValidity: validity, wipeCount: wipeCount) }.value
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
            onFolderChanged?(folder)
            if detail == nil {
                loadState = .failed(MailAccountManager.LoginError(MailClientError.folderChanged).message)
            } else {
                actionError = MailAccountManager.LoginError(MailClientError.folderChanged).message
            }
        } catch {
            if detail == nil {
                loadState = .failed(MailAccountManager.LoginError(error).message)
            } else {
                actionError = MailAccountManager.LoginError(error).message
            }
        }
    }

    func loadImages() async {
        allowRemoteImages = true
        guard let html = detail?.htmlBody else { return }
        guard let computed = await recomputeSanitizedHTML(html: html, textBody: nil, allowImages: true) else { return }
        sanitized = computed.0
        linkedDocument = computed.1
        pages = computed.3
    }

    /// `BODY.PEEK[]`: never marks the mail read. No size prompt: `MailSourceTextView` lays out
    /// only the visible viewport, so a multi-megabyte source costs a download, not a frozen
    /// screen.
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
        let wipeCount = cache.wipeCount
        if let validity,
           let cached = await Task.detached(operation: { cache.loadSource(folder: folder, uidValidity: validity, uid: uid) }).value {
            source = cached
            return
        }
        do {
            let data = try await session.use { client in
                try await client.rawSource(folder: folder, uid: uid, expectedUIDValidity: validity)
            }
            let text = await Task.detached { String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "" }.value
            source = text
            if let validity, prefs.studentID == account {
                await Task.detached { cache.saveSource(text, folder: folder, uidValidity: validity, uid: uid, wipeCount: wipeCount) }.value
            }
        } catch {
            actionError = MailAccountManager.LoginError(error).message
            sourceLoadFailed = true
        }
    }

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

    func prepareDelete() async -> Bool {
        guard folderRoles[.trash] == nil, !isMoving else { return deleteIsPermanent }
        isMoving = true
        defer { isMoving = false }
        await ensureFolder(.trash)
        return deleteIsPermanent
    }

    func delete() async -> Bool {
        if !deleteIsPermanent, let trash = folderRoles[.trash] {
            return await move(to: trash)
        }
        return await performMove { client, owned in
            try await MailMover.deletePermanently(uids: [self.route.uid], in: self.route.folder, client: client, previouslyFlagged: owned)
        }
    }

    private func ensureFolder(_ role: MailFolderRole) async {
        let known = folderRoles
        let ensured = try? await session.use { client in
            await MailFolderProvisioner.ensure(role, in: known, client: client)
        }
        guard let ensured = ensured ?? nil else { return }
        adoptFolderRoles(ensured.roles)
    }

    func adoptFolderRoles(_ roles: [MailFolderRole: String]) {
        guard roles != folderRoles else { return }
        folderRoles = roles
        onFolderRolesChanged?(roles)
    }

    func reportSentCopyNotice(_ message: String) {
        actionError = message
    }

    private func performMove(_ operation: @escaping (any MailClient, OwnedDeleted) async throws -> MailMoveResult) async -> Bool {
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

    func prepareAttachment(_ part: MailBodyPart) async -> URL? {
        guard !downloading.contains(part.section) else { return nil }
        downloading.insert(part.section)
        defer { downloading.remove(part.section) }
        let folder = route.folder
        let uid = route.uid
        let validity = pageUIDValidity
        let cache = self.cache
        let wipeCount = cache.wipeCount
        do {
            let data = try await session.use { client in
                try await client.attachment(folder: folder, uid: uid, part: part, expectedUIDValidity: validity)
            }
            let filename = MailWarnings.displayFilename(part.filename ?? "attachment")
            return try await Task.detached {
                try cache.saveAttachment(data, filename: filename, wipeCount: wipeCount)
            }.value
        } catch {
            actionError = MailAccountManager.LoginError(error).message
            return nil
        }
    }

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

    func linkTarget(forIndex index: Int) -> MailLinkTarget? {
        guard let links = linkedDocument?.links, links.indices.contains(index) else { return nil }
        let link = links[index]
        return Self.target(text: link.text, href: link.href)
    }

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

    nonisolated static func detachedCancellably<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func recomputeSanitizedHTML(
        html: String?, textBody: String?, allowImages: Bool
    ) async -> (SanitizedHTML?, LinkedHTML?, String, MailFormattedPages?)? {
        htmlGeneration += 1
        let generation = htmlGeneration
        let computed = await Self.detachedCancellably { () -> (SanitizedHTML?, LinkedHTML?, String, MailFormattedPages?)? in
            guard let html else { return (nil, nil, textBody ?? "", nil) }
            let sanitized = MailHTMLSanitizer.sanitize(html, allowRemoteImages: allowImages)
            guard !Task.isCancelled else { return nil }
            let linked = MailHTMLSanitizer.rewriteLinks(sanitized.html)
            guard !Task.isCancelled else { return nil }
            let readable = MailReadableHTML(linked.html)
            let pages = MailFormattedPages(
                app: readable.html(on: .app),
                light: readable.html(on: .light),
                setsColors: readable.setsColors
            )
            guard !Task.isCancelled else { return nil }
            let plain = textBody ?? MailHTMLSanitizer.plainText(fromHTML: sanitized.html)
            return Task.isCancelled ? nil : (sanitized, linked, plain, pages)
        }
        guard let computed, generation == htmlGeneration else { return nil }
        return computed
    }

    private func apply(_ detail: MailMessageDetail) async {
        guard let computed = await recomputeSanitizedHTML(html: detail.htmlBody, textBody: detail.textBody, allowImages: allowRemoteImages) else {
            return
        }
        self.detail = detail
        let (freshSanitized, freshLinked, freshPlainText, freshPages) = computed
        sanitized = freshSanitized
        linkedDocument = freshLinked
        pages = freshPages
        if !hasPickedPage, let freshPages {
            viewsInLightMode = freshPages.setsColors
            hasPickedPage = true
        }
        plainText = freshPlainText
        linkedPlainText = MailTextLinkifier.attributed(freshPlainText)
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
            returnPath: detail.returnPath
        ))
        loadState = .loaded
    }
}
#endif
