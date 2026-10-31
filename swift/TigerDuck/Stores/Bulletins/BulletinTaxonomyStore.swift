import Foundation
import Observation
import os

@MainActor
@Observable
final class BulletinTaxonomyStore {
    static let shared = BulletinTaxonomyStore()

    enum State: Sendable {
        case idle
        case loading
        case loaded(BulletinAPI.TaxonomyResponse)
        case failed(String)

        var taxonomy: BulletinAPI.TaxonomyResponse? {
            if case .loaded(let t) = self { return t }
            return nil
        }
    }

    private(set) var state: State = .idle
    private let apiClient: BulletinAPIClient
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Bulletin.Taxonomy")

    init(apiClient: BulletinAPIClient? = nil) {
        self.apiClient = apiClient ?? BulletinAPIClient()
    }

    func loadIfNeeded() async {
        if case .loaded = state { return }
        if case .loading = state { return }
        state = .loading
        do {
            let payload = try await apiClient.getTaxonomy()
            state = .loaded(payload)
        } catch {
            logger.error("taxonomy load failed: \(error.localizedDescription, privacy: .private)")
            state = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        state = .loading
        do {
            let payload = try await apiClient.getTaxonomy()
            state = .loaded(payload)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func orgLabel(for rawId: String) -> String {
        guard case .loaded(let tax) = state else { return rawId }
        return tax.orgs.first(where: { $0.rawId == rawId })?.label ?? rawId
    }

    func tagLabel(for rawId: String) -> String {
        if rawId == "server_notification" {
            return String(localized: "tag_server_notification")
        }
        guard case .loaded(let tax) = state else { return rawId }
        return tax.tags.first(where: { $0.rawId == rawId })?.label ?? rawId
    }
}
