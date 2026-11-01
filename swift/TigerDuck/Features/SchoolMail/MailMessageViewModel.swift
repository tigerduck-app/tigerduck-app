#if os(iOS)
import Foundation
import Observation

struct MailMessageRoute: Hashable {
    var folder: String
    var uid: UInt32
    var uidValidity: UInt32? = nil
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
    private(set) var content = MailMessageContent()
    private(set) var display = MailMessageDisplay()
    var activity = MailMessageActivity()
    private(set) var folderRoles: [MailFolderRole: String]
    @ObservationIgnored let events: MailboxEvents
    @ObservationIgnored let session: MailPageSession
    @ObservationIgnored let stores: MailMessageStores
    @ObservationIgnored private(set) var pageUIDValidity: UInt32?
    @ObservationIgnored private var htmlGeneration = 0

    init(
        route: MailMessageRoute,
        session: MailPageSession,
        folderRoles: [MailFolderRole: String],
        events: MailboxEvents? = nil,
        cache: MailCache? = nil,
        prefs: (any MailPreferences)? = nil,
        notifier: MailNotifier = MailChecker.shared.notifier
    ) {
        self.route = route
        self.session = session
        self.folderRoles = folderRoles
        self.events = events ?? MailboxEvents()
        stores = MailMessageStores(cache: cache ?? MailAccountManager.shared.cache,
                                   prefs: prefs ?? MailAccountManager.shared.prefs, notifier: notifier)
    }

    var detail: MailMessageDetail? { content.detail }
    var cachedSummary: MailSummary? { content.cachedSummary }
    var loadState: LoadState { content.loadState }
    var sanitized: SanitizedHTML? { content.sanitized }
    var linkedDocument: LinkedHTML? { content.linkedDocument }
    var pages: MailFormattedPages? { content.pages }
    var plainText: String { content.plainText }
    var linkedPlainText: AttributedString { content.linkedPlainText }
    var warnings: [MailWarning] { content.warnings }
    var hasNothingRenderable: Bool { content.hasNothingRenderable }
    var source: String? { activity.source }
    var sourceLoadFailed: Bool { activity.sourceLoadFailed }
    var actionError: String? { activity.actionError }
    var isMoving: Bool { activity.isMoving }
    var downloading: Set<String> { activity.downloading }
    var allowRemoteImages: Bool { display.allowRemoteImages }
    var mode: ViewMode {
        get { display.mode }
        set { display.mode = newValue }
    }
    var viewsInLightMode: Bool {
        get { display.viewsInLightMode }
        set { display.viewsInLightMode = newValue }
    }
    var appearsLight: Bool {
        get { display.appearsLight }
        set { display.appearsLight = newValue }
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

    var original: MailOriginal? { detail.map { MailOriginal(detail: $0, bodyText: plainText) } }

    func load() async {
        let signIn = await session.account.startingSignIn
        let cache = stores.cache
        let prefs = stores.prefs
        let folder = route.folder
        let uid = route.uid
        let wipeCount = cache.wipeCount
        let cachedPage = await Task.detached { cache.loadPage(folder: folder) }.value
        let validity = route.uidValidity ?? cachedPage?.uidValidity
        let page = cachedPage?.uidValidity == validity ? cachedPage : nil
        pageUIDValidity = validity
        if detail == nil {
            content.cachedSummary = page?.summaries.first { $0.uid == uid }
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
            if let validity, signIn.isCurrent {
                await Task.detached { cache.saveDetail(fresh, folder: folder, uidValidity: validity, unlessWipedSince: wipeCount) }.value
            }
            if !fresh.summary.isSeen {
                try await session.use { client in
                    try await client.setFlag(.seen, on: true, folder: folder, uids: [uid], expectedUIDValidity: validity)
                }
                content.detail?.summary.isSeen = true
                events.post(.seen(folder: folder, uid: uid, isSeen: true))
                if folder == MailConstants.inbox, let inboxValidity = prefs.inboxUIDValidity {
                    stores.notifier.removeNotification(uidValidity: inboxValidity, uid: uid)
                }
            }
        } catch {
            if (error as? MailClientError) == .folderChanged { events.post(.folderChanged(folder)) }
            let message = MailAccountManager.LoginError(error).message
            if detail == nil {
                content.loadState = .failed(message)
            } else {
                activity.actionError = message
            }
        }
    }

    func loadImages() async {
        guard !stores.prefs.demoActive else { return }
        display.allowRemoteImages = true
        guard let html = detail?.htmlBody else { return }
        guard let rendered = try? await render(html: html, textBody: nil, allowImages: true) else { return }
        content.sanitized = rendered.sanitized
        content.linkedDocument = rendered.linked
        content.pages = rendered.pages
    }

    func loadSource() async { await MailMessageActions.loadSource(model: self) }

    func toggleSeen() async {
        guard let seen = detail?.summary.isSeen else { return }
        let folder = route.folder
        let uid = route.uid
        do {
            let validity = pageUIDValidity
            try await session.use { client in
                try await client.setFlag(.seen, on: !seen, folder: folder, uids: [uid], expectedUIDValidity: validity)
            }
            content.detail?.summary.isSeen = !seen
            events.post(.seen(folder: folder, uid: uid, isSeen: !seen))
        } catch MailClientError.folderChanged {
            activity.actionError = MailAccountManager.LoginError(MailClientError.folderChanged).message
            events.post(.folderChanged(folder))
        } catch {
            activity.actionError = MailAccountManager.LoginError(error).message
        }
    }

    func move(to target: String) async -> Bool { await MailMessageActions.move(model: self, to: target) }
    func prepareDelete() async -> Bool { await MailMessageActions.prepareDelete(model: self) }
    func delete() async -> Bool { await MailMessageActions.delete(model: self) }

    func adoptFolderRoles(_ roles: [MailFolderRole: String]) {
        guard roles != folderRoles else { return }
        folderRoles = roles
        events.post(.folderRoles(roles))
    }

    func reportSentCopyNotice(_ message: String) {
        activity.actionError = message
    }

    func prepareAttachment(_ part: MailBodyPart) async -> URL? {
        await MailMessageActions.prepareAttachment(part, model: self)
    }

    func isRisky(_ part: MailBodyPart) -> Bool {
        let context = (detail?.summary.subject ?? "") + "\n" + plainText
        if MailAttachmentRisk.attachmentRisk(filename: part.filename ?? "", contentType: part.contentType,
                                             subjectAndBody: context) != nil { return true }
        return isNeverRenderedInApp(part)
    }

    func isNeverRenderedInApp(_ part: MailBodyPart) -> Bool {
        MailAttachmentRisk.neverRenderedInApp(filename: part.filename ?? "", contentType: part.contentType)
    }

    func linkTarget(forIndex index: Int) -> MailLinkTarget? {
        guard let links = linkedDocument?.links, links.indices.contains(index) else { return nil }
        let link = links[index]
        return MailLinkTarget.target(text: link.text, href: link.href)
    }

    func linkTarget(forPlainText url: URL) -> MailLinkTarget {
        MailLinkTarget.target(text: url.absoluteString, href: url.absoluteString)
    }

    private func render(html: String?, textBody: String?, allowImages: Bool) async throws -> MailMessageRenderer.Rendered {
        htmlGeneration += 1
        let generation = htmlGeneration
        let rendered = try await MailMessageRenderer.render(html: html, textBody: textBody, allowImages: allowImages)
        guard generation == htmlGeneration else { throw CancellationError() }
        return rendered
    }

    private func apply(_ detail: MailMessageDetail) async {
        guard let rendered = try? await render(html: detail.htmlBody, textBody: detail.textBody,
                                          allowImages: allowRemoteImages) else { return }
        content.detail = detail
        content.sanitized = rendered.sanitized
        content.linkedDocument = rendered.linked
        content.pages = rendered.pages
        if !display.hasPickedPage, let pages = rendered.pages {
            display.viewsInLightMode = pages.setsColors
            display.hasPickedPage = true
        }
        content.plainText = rendered.plainText
        content.linkedPlainText = MailTextLinkifier.attributed(rendered.plainText)
        if rendered.linked == nil, mode == .formatted { mode = .plain }
        content.hasNothingRenderable = detail.textBody == nil && detail.htmlBody == nil && detail.attachments.isEmpty
        if hasNothingRenderable { mode = .source }
        content.warnings = MailMessageRenderer.warnings(for: detail, plainText: plainText, links: rendered.sanitized?.links ?? [])
        content.loadState = .loaded
    }
}
#endif
