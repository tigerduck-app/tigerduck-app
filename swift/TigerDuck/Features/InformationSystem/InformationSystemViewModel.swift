import Foundation

@Observable
@MainActor
final class InformationSystemViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case failed(String)
    }

    struct Request: Equatable {
        let studentId: String
        let password: String
        let language: PortalLanguage
        let signIn: SignIn
    }

    struct Section: Equatable {
        let category: PortalCategory
        let links: [PortalLink]
    }

    private(set) var links: [PortalLink] = []
    private(set) var phase = Phase.idle
    private(set) var fetchedAt: Date?
    var category: PortalCategory?
    var query = ""

    @ObservationIgnored private let store: PortalLinks
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var fetching: Request?

    init(store: PortalLinks? = nil, showing request: Request? = nil) {
        self.store = store ?? PortalLinks()
        show(request)
    }

    var sections: [Section] { Self.sections(of: links, in: category, matching: query) }

    var status: ServerStatus {
        if case .failed = phase { return .failed }
        return fetchedAt == nil ? .unknown : .ok
    }

    func open(_ request: Request?) async {
        show(request)
        guard let request else { return }
        if let fetchedAt, !links.isEmpty, PortalLinks.freshness.isFresh(storedAt: fetchedAt, now: store.now()) {
            return
        }
        let unreadable = store.recentUnreadablePage(studentId: request.studentId, language: request.language, for: request.signIn)
        if let unreadable {
            phase = .failed(unreadable)
            return
        }
        await fetch(request)
    }

    private func show(_ request: Request?) {
        guard request != self.request else { return }
        self.request = request
        let saved = request.flatMap { store.saved(studentId: $0.studentId, language: $0.language) }
        links = saved?.links ?? []
        fetchedAt = saved?.fetchedAt
        phase = .idle
        category = nil
        query = ""
    }

    func refresh() async {
        guard let request else { return }
        await fetch(request)
    }

    private func fetch(_ request: Request) async {
        guard fetching != request else { return }
        fetching = request
        defer { if fetching == request { fetching = nil } }
        phase = .loading
        do {
            let fresh = try await store.fetch(
                studentId: request.studentId, password: request.password, language: request.language, for: request.signIn
            )
            guard request == self.request, request.signIn.isCurrent else { return }
            links = fresh.links
            fetchedAt = fresh.fetchedAt
            phase = .idle
        } catch {
            guard request == self.request, request.signIn.isCurrent else { return }
            phase = AppLogger.isCancellation(error) ? .idle : .failed(error.localizedDescription)
        }
    }

    enum LinkBrowser { case inApp, system }

    enum LinkTarget: Equatable {
        case address(URL)
        case demoPage(PortalLink)
    }

    /// The system browser would load a demo link from the school.
    static func target(of link: PortalLink, isDemo: Bool, browser: LinkBrowser) -> LinkTarget {
        isDemo && browser == .system ? .demoPage(link) : .address(link.url)
    }

    static func sections(of links: [PortalLink], in category: PortalCategory?, matching query: String) -> [Section] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return PortalCategory.allCases.compactMap { shown in
            guard category == nil || category == shown else { return nil }
            let grouped = links.filter { $0.category == shown }
            let all = needle.isEmpty || String(localized: shown.titleKey).localizedStandardContains(needle)
            let matching = all ? grouped : grouped.filter { $0.name.localizedStandardContains(needle) }
            return matching.isEmpty ? nil : Section(category: shown, links: matching)
        }
    }
}
