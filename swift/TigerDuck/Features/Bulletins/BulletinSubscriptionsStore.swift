import Foundation
import Observation
import os

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

    var pending: [BulletinAPI.SubscriptionRule] = []
    private(set) var loadState: LoadState = .idle
    private(set) var saveState: SaveState = .idle
    private(set) var isDirty: Bool = false

    private var apiClient: BulletinAPIClient
    private let usesInjectedClient: Bool
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Bulletin.Subs")

    init(apiClient: BulletinAPIClient? = nil) {
        self.apiClient = apiClient ?? BulletinAPIClient()
        self.usesInjectedClient = apiClient != nil
    }

    func configure(authTokenManager: AuthTokenManager) {
        guard !usesInjectedClient else { return }
        apiClient = BulletinAPIClient(
            authHeaderProvider: { await authTokenManager.authorizationHeader() }
        )
    }

    func load() async {
        if case .loading = loadState { return }
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
            logger.error("subscription load failed: \(error.localizedDescription, privacy: .private)")
            loadState = .failed(error.localizedDescription)
        }
    }

    func save() async {
        saveState = .saving
        logger.info("subscription save starting ruleCount=\(self.pending.count, privacy: .public)")
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
                let delayMs = 250 * (1 << (attempt - 1))
                logger.info("PUT subscriptions 404 (attempt \(attempt, privacy: .public)); retrying in \(delayMs, privacy: .public)ms")
                try? await Task.sleep(for: .milliseconds(delayMs))
                if Task.isCancelled { return }
            } catch {
                logger.error("subscription save failed: \(error.localizedDescription, privacy: .private)")
                saveState = .failed(error.localizedDescription)
                return
            }
        }
        logger.error("subscription save gave up after \(maxAttempts, privacy: .public) 404 attempts")
        saveState = .failed(String(localized: "bulletin_subscription_device_not_registered"))
    }

    func makeNewRule() -> BulletinAPI.SubscriptionRule {
        BulletinAPI.SubscriptionRule(
            name: nil,
            orgs: [],
            tags: [],
            mode: .and,
            enabled: true
        )
    }

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

    func clearSaveState() {
        if case .failed = saveState {
            saveState = .idle
        } else if case .saved = saveState {
            saveState = .idle
        }
    }

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
