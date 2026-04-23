import Foundation
import Observation
import os

/// @Observable store for the subscription editor page.
///
/// Rules live in memory as drafts (`pending`) until the user hits save.
/// That gives the editor a clean undo (just re-load) and avoids hitting
/// the server on every keystroke. The snapshot-replacement PUT means
/// even a mid-edit crash leaves the server consistent.
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
    /// True when `pending` no longer matches what's on the server. Used by
    /// the settings page to gate the 儲存 toolbar item — we only want to
    /// nag the user when there's actual unsaved work.
    private(set) var isDirty: Bool = false

    private let apiClient: BulletinAPIClient
    private let deviceId: String
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Bulletin.Subs")

    init(
        apiClient: BulletinAPIClient? = nil,
        identity: PushIdentity = .loadOrCreate()
    ) {
        self.apiClient = apiClient ?? BulletinAPIClient(
            baseURL: PushCoordinator.resolveServerURL(),
            sharedSecret: PushCoordinator.resolveSharedSecret()
        )
        self.deviceId = identity.deviceId
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
        // Never overwrite unsaved edits. Earlier iteration of the page
        // had two paths that could fire `load()` concurrently (view
        // `.task` + `onChange(of: pushEnabled)`) — the second firing
        // happily wiped a freshly-added rule to an empty array because
        // the server had nothing yet. Guarding on `isDirty` lets the
        // user's in-flight edits survive any number of re-triggers.
        if isDirty {
            logger.info("subscriptions load skipped (dirty): pendingCount=\(self.pending.count, privacy: .public)")
            return
        }
        loadState = .loading
        do {
            let response = try await apiClient.getSubscriptions(deviceId: deviceId)
            pending = response.rules
            isDirty = false
            loadState = .loaded
            logger.info("subscriptions loaded device=\(self.deviceId, privacy: .public) count=\(response.rules.count, privacy: .public)")
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
        logger.info("subscription save starting device=\(self.deviceId, privacy: .public) ruleCount=\(self.pending.count, privacy: .public)")
        // Snapshot the pre-save clientIds in their current order. The server
        // PUT does delete + insert preserving order, so the response rules
        // line up with the request rules positionally. We re-attach the
        // original clientIds to the response so any closure that captured a
        // rule's clientId before save (e.g. an open editor pushed via
        // NavigationLink) still finds the row in `update()`'s
        // `firstIndex(where:)` lookup. Without this, post-save edits
        // silently no-op because the decoded clientIds are fresh UUIDs.
        let snapshotClientIds = pending.map(\.clientId)
        let maxAttempts = 4
        for attempt in 1...maxAttempts {
            do {
                let response = try await apiClient.putSubscriptions(
                    deviceId: deviceId,
                    rules: pending
                )
                var preserved = response.rules
                for (i, oldId) in snapshotClientIds.enumerated() where i < preserved.count {
                    preserved[i].clientId = oldId
                }
                pending = preserved
                isDirty = false
                saveState = .saved
                logger.info("subscription save success device=\(self.deviceId, privacy: .public) serverCount=\(response.rules.count, privacy: .public)")
                return
            } catch BulletinAPIError.httpStatus(let code, _) where code == 404 {
                if attempt == maxAttempts {
                    break
                }
                // Backoff: 250ms, 500ms, 1000ms. Total worst case ~1.75s.
                let delayMs = 250 * (1 << (attempt - 1))
                logger.info("PUT subscriptions 404 (attempt \(attempt, privacy: .public)); retrying in \(delayMs, privacy: .public)ms")
                try? await Task.sleep(for: .milliseconds(delayMs))
            } catch {
                logger.error("subscription save failed: \(error.localizedDescription, privacy: .public)")
                saveState = .failed(error.localizedDescription)
                return
            }
        }
        logger.error("subscription save gave up after \(maxAttempts, privacy: .public) 404 attempts")
        saveState = .failed("設備尚未註冊，請稍後再儲存")
    }

    // MARK: - Mutation helpers

    /// Append a fresh blank rule and return its `clientId` so the caller
    /// can immediately push the editor for it. Returning the id avoids the
    /// "guess the index" pattern and pairs cleanly with
    /// `.navigationDestination(item:)` for programmatic navigation.
    @discardableResult
    func addRule() -> UUID {
        let new = BulletinAPI.SubscriptionRule(
            name: nil,
            orgs: [],
            tags: [],
            mode: .and,
            enabled: true
        )
        pending.append(new)
        isDirty = true
        saveState = .idle
        logger.info("addRule clientId=\(new.clientId.uuidString, privacy: .public) pendingCount=\(self.pending.count, privacy: .public)")
        return new.clientId
    }

    func removeRule(clientId: UUID) {
        let before = pending.count
        pending.removeAll { $0.clientId == clientId }
        if pending.count != before { isDirty = true }
        saveState = .idle
    }

    func update(_ rule: BulletinAPI.SubscriptionRule) {
        guard let index = pending.firstIndex(where: { $0.clientId == rule.clientId }) else { return }
        if pending[index] != rule {
            pending[index] = rule
            isDirty = true
        }
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
                name: "預設推薦",
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
