import Foundation
import Observation
import os

/// Process-level cache for the taxonomy lookup. The orgs/tags set changes
/// rarely (only when the server enums evolve), so we fetch on first use and
/// keep the result in memory for the lifetime of the app.
///
/// Exposed as a shared singleton (`BulletinTaxonomyStore.shared`) so that
/// navigating into `BulletinsView` from the Home widget — which re-creates
/// the view on every push — does not re-fetch the taxonomy and block the
/// filter chips behind a network round-trip on each entry.
///
/// Falls back to an empty taxonomy on error — the list view degrades
/// gracefully (no filter chips) and the subscription editor surfaces the
/// error so the user can retry.
@MainActor
@Observable
final class BulletinTaxonomyStore {
    /// Shared instance. Safe to hold a direct reference in views: SwiftUI
    /// tracks `@Observable` property access regardless of whether the
    /// instance is `@State`-owned.
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

    /// Fetch the taxonomy if we do not already have a loaded copy. Safe
    /// to call repeatedly; a concurrent second caller will see the final
    /// state after the first call resolves.
    func loadIfNeeded() async {
        if case .loaded = state { return }
        if case .loading = state { return }
        state = .loading
        do {
            let payload = try await apiClient.getTaxonomy()
            state = .loaded(payload)
        } catch {
            logger.error("taxonomy load failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Force a refresh regardless of current state.
    func refresh() async {
        state = .loading
        do {
            let payload = try await apiClient.getTaxonomy()
            state = .loaded(payload)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Lookup a human-readable label for an org id. Returns the raw id if
    /// the taxonomy has not loaded yet or the id is unknown, so the UI
    /// still has something to render.
    func orgLabel(for rawId: String) -> String {
        guard case .loaded(let tax) = state else { return rawId }
        return tax.orgs.first(where: { $0.rawId == rawId })?.label ?? rawId
    }

    func tagLabel(for rawId: String) -> String {
        // Operator-issued "server" notifications need a per-locale label
        // (unlike every other tag, which the server ships zh-only).
        // Intercept that one id and return the localized string instead
        // of whatever the server sent.
        if rawId == "server_notification" {
            return String(localized: "tag_server_notification")
        }
        guard case .loaded(let tax) = state else { return rawId }
        return tax.tags.first(where: { $0.rawId == rawId })?.label ?? rawId
    }
}
