import Foundation
import Observation
import os

/// @Observable store for the subscription editor page.
///
/// Rules live in memory as drafts (`pending`) until the user hits save.
/// That gives the editor a clean undo (just re-load) and avoids hitting
/// the server on every keystroke. The v3 backend exposes individual CRUD
/// endpoints, but this store retains the snapshot-replacement model for
/// simplicity: load all → edit locally → PUT all. Migrating to per-rule
/// CRUD is tracked separately.
@MainActor
@Observable
final class BulletinSubscriptionsStore {
    enum LoadState: Sendable, Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum SaveState: Sendable, Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    /// Rules currently visible in the editor. Mutated in place through the
    /// mutation helpers below so SwiftUI diffing stays happy.
    var pending: [BulletinAPI.SubscriptionRule] = []
    private(set) var loadState: LoadState = .idle
    private(set) var saveState: SaveState = .idle
    /// True when `pending` differs from what is on the server. The settings page saves on leaving
    /// only when this is set, so it acts only on actual unsaved work.
    private(set) var isDirty: Bool = false

    private var apiClient: BulletinAPIClient
    private let usesInjectedClient: Bool
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Bulletin.Subs")

    init(apiClient: BulletinAPIClient? = nil) {
        self.apiClient = apiClient ?? BulletinAPIClient()
        self.usesInjectedClient = apiClient != nil
    }

    /// Inject the app's v3 auth so subscription requests carry the Bearer
    /// token. The `/bulletin-subscriptions` endpoints are identity-scoped
    /// and Bearer-protected; without this the GET/PUT go out with no
    /// Authorization header and 401. A `@State` store can't read the SwiftUI
    /// environment at init, so the editor page calls this from `.task`
    /// before the first `load()`. No-op when a client was injected (tests).
    func configure(authTokenManager: AuthTokenManager) {
        guard !usesInjectedClient else { return }
        apiClient = BulletinAPIClient(
            authHeaderProvider: { await authTokenManager.authorizationHeader() }
        )
    }

    // MARK: - Lifecycle

    /// Load existing rules from the server. Safe to call repeatedly; a
    /// second call while loading is coalesced by the state guard.
    ///
    /// The server returns an empty list (not 404) when the device row
    /// isn't registered yet — that handles the first-launch race where the
    /// editor opens before APNs registration finishes.
    func load() async {
        if case .loading = loadState { return }
        // Never overwrite unsaved edits: a repeated `load()` would replace a freshly added rule
        // with the server's list, which may still be empty. Guarding on `isDirty` lets edits
        // survive any number of re-triggers.
        if isDirty {
            logger.info("subscriptions load skipped (dirty): pendingCount=\(self.pending.count, privacy: .public)")
            return
        }
        loadState = .loading
        do {
            let response = try await apiClient.getSubscriptions()
            pending = response.items
            isDirty = false
            loadState = .loaded
            logger.info("subscriptions loaded count=\(response.items.count, privacy: .public)")
        } catch {
            logger.error("subscription load failed: \(error.localizedDescription, privacy: .public)")
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Replace the rule set on the server with the current `pending`.
    ///
    /// The PUT path still requires a registered device; if the user
    /// closes the editor before APNs registration completes, the first
    /// attempt comes back 404. Retry with short backoff so registration
    /// usually wins within a second or two — APNs handshake on a warm
    /// simulator is sub-second.
    func save() async {
        saveState = .saving
        logger.info("subscription save starting ruleCount=\(self.pending.count, privacy: .public)")
        // The PUT deletes and reinserts in order, so response rules line up with the request by
        // position. Decoded rules get fresh UUIDs, so the pre-save clientIds are restored: any
        // closure that captured one before the save, like an open editor, must still find its row.
        let snapshotClientIds = pending.map(\.clientId)
        let maxAttempts = 4
        for attempt in 1...maxAttempts {
            do {
                let response = try await apiClient.putSubscriptions(rules: pending)
                var preserved = response.items
                for (i, oldId) in snapshotClientIds.enumerated() where i < preserved.count {
                    preserved[i].clientId = oldId
                }
                pending = preserved
                isDirty = false
                saveState = .saved
                logger.info("subscription save success serverCount=\(response.items.count, privacy: .public)")
                return
            } catch BulletinAPIError.httpStatus(let code, _) where code == 404 {
                if attempt == maxAttempts {
                    break
                }
                // Backoff: 250ms, 500ms, 1000ms. Total worst case ~1.75s.
                let delayMs = 250 * (1 << (attempt - 1))
                logger.info("PUT subscriptions 404 (attempt \(attempt, privacy: .public)); retrying in \(delayMs, privacy: .public)ms")
                try? await Task.sleep(for: .milliseconds(delayMs))
                if Task.isCancelled { return }
            } catch {
                logger.error("subscription save failed: \(error.localizedDescription, privacy: .public)")
                saveState = .failed(error.localizedDescription)
                return
            }
        }
        logger.error("subscription save gave up after \(maxAttempts, privacy: .public) 404 attempts")
        saveState = .failed(String(localized: "bulletin_subscription_device_not_registered"))
    }

    // MARK: - Mutation helpers

    /// Builds a blank rule for the editor without touching `pending`. The caller holds it as a
    /// draft until the editor's Done path calls `upsert`, so tapping Add rule and swiping back
    /// without Done discards it instead of persisting an empty placeholder.
    func makeNewRule() -> BulletinAPI.SubscriptionRule {
        BulletinAPI.SubscriptionRule(
            name: nil,
            orgs: [],
            tags: [],
            mode: .and,
            enabled: true
        )
    }

    /// Insert a newly-committed draft or update an existing rule in place.
    /// `isDirty` flips only when the value actually changes, so a no-op
    /// Done tap on an existing rule doesn't force a save.
    func upsert(_ rule: BulletinAPI.SubscriptionRule) {
        if let index = pending.firstIndex(where: { $0.clientId == rule.clientId }) {
            if pending[index] != rule {
                pending[index] = rule
                isDirty = true
                logger.info("upsert updated clientId=\(rule.clientId.uuidString, privacy: .public)")
            }
        } else {
            pending.append(rule)
            isDirty = true
            logger.info("upsert appended clientId=\(rule.clientId.uuidString, privacy: .public) pendingCount=\(self.pending.count, privacy: .public)")
        }
        saveState = .idle
    }

    func removeRule(clientId: UUID) {
        let before = pending.count
        pending.removeAll { $0.clientId == clientId }
        if pending.count != before { isDirty = true }
        saveState = .idle
    }

    /// Acknowledge a `.failed` save so the toolbar drops the indicator
    /// and the alert binding reads false. Idempotent on `.idle/.saving`.
    func clearSaveState() {
        if case .failed = saveState {
            saveState = .idle
        } else if case .saved = saveState {
            saveState = .idle
        }
    }

    /// Seed a "follow the defaults" rule when the user starts from zero.
    func seedDefault(from taxonomy: BulletinAPI.TaxonomyResponse) {
        guard pending.isEmpty else { return }
        pending.append(
            BulletinAPI.SubscriptionRule(
                name: String(localized: "bulletin_subscription_default_seed_name"),
                orgs: [],
                tags: taxonomy.defaultTags,
                mode: .or,
                enabled: true
            )
        )
        isDirty = true
        saveState = .idle
    }
}
