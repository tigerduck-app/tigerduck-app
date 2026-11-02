import Foundation

@Observable
@MainActor
final class InformationSystemViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case failed(String)
    }

    /// The account, sign-in and language links are shown for; a load for another is dropped.
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

    /// Shows the saved links of `request` from the start.
    init(store: PortalLinks? = nil, showing request: Request? = nil) {
        self.store = store ?? PortalLinks()
        show(request)
    }

    var sections: [Section] { Self.sections(of: links, in: category, matching: query) }

    /// The school's answer to the last read, for the status dot; a failure there leaves the
    /// shown links in place.
    var status: ServerStatus {
        if case .failed = phase { return .failed }
        return fetchedAt == nil ? .unknown : .ok
    }

    /// Shows the saved links of `request`, then reads the school's when none are saved or they
    /// are older than `PortalLinks.freshness`, unless a read failed within it. Nil, signed out,
    /// shows nothing.
    func open(_ request: Request?) async {
        show(request)
        guard let request else { return }
        if let fetchedAt, !links.isEmpty, PortalLinks.freshness.isFresh(storedAt: fetchedAt, now: store.now()) {
            return
        }
        if let message = store.recentFailure(language: request.language, for: request.signIn) {
            phase = .failed(message)
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
        query = ""
    }

    /// Reads the school's links again, for a pull or a retry.
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

    /// The links of `category`, or of every category, whose name or category name holds `query`,
    /// ignoring case and diacritics, grouped in the portal's order.
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
