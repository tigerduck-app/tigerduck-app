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
    func load() async {
        if case .loading = loadState { return }
        loadState = .loading
        do {
            let response = try await apiClient.getSubscriptions(deviceId: deviceId)
            pending = response.rules
            loadState = .loaded
        } catch BulletinAPIError.httpStatus(let code, _) where code == 404 {
            // 404 means the device row is not yet registered on the server.
            // That happens when the user opens the editor before the first
            // push registration completes. Show an empty list so the user
            // can still draft rules — the save path handles re-registration.
            logger.info("device not registered on server yet; starting with empty rules")
            pending = []
            loadState = .loaded
        } catch {
            logger.error("subscription load failed: \(error.localizedDescription, privacy: .public)")
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Replace the rule set on the server with the current `pending`.
    func save() async {
        saveState = .saving
        do {
            let response = try await apiClient.putSubscriptions(
                deviceId: deviceId,
                rules: pending
            )
            pending = response.rules
            saveState = .saved
        } catch {
            logger.error("subscription save failed: \(error.localizedDescription, privacy: .public)")
            saveState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Mutation helpers

    func addRule() {
        pending.append(
            BulletinAPI.SubscriptionRule(
                name: nil,
                orgs: [],
                tags: [],
                mode: .and,
                enabled: true
            )
        )
        saveState = .idle
    }

    func removeRule(clientId: UUID) {
        pending.removeAll { $0.clientId == clientId }
        saveState = .idle
    }

    func update(_ rule: BulletinAPI.SubscriptionRule) {
        guard let index = pending.firstIndex(where: { $0.clientId == rule.clientId }) else { return }
        pending[index] = rule
        saveState = .idle
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
        saveState = .idle
    }
}
