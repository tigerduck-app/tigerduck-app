#if os(iOS)
import Defaults
import Foundation
import os

/// Sends and reconciles the notification settings document, one queued link at a time
/// (`NotificationSettingsPushQueue`).
@MainActor
final class NotificationSettingsSyncer {
    private let authTokenManager: AuthTokenManager
    private let preferences: LiveActivityPreferencesStore

    init(authTokenManager: AuthTokenManager, preferences: LiveActivityPreferencesStore) {
        self.authTokenManager = authTokenManager
        self.preferences = preferences
    }


    /// Whether the push landed and nothing changed here since, which leaves nothing to send.
    @discardableResult
    func push(isCurrent: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        guard Defaults[.cloudSyncEnabled] else { return false }
        guard await authTokenManager.isLoggedIn, isCurrent() else { return false }

        let atm = authTokenManager
        let client = SettingsDocumentClient(
            authHeaderProvider: { await atm.authorizationHeader() }
        )
        let local = NotificationSettingsSync.LocalPreferences(from: preferences)
        var sent: [String: Any] = [:]
        do {
            let written = try await NotificationSettingsSync.push(
                local: local,
                base: NotificationSettingsSync.pushBase(local: local),
                client: client,
                cloudSyncEnabled: Defaults[.cloudSyncEnabled],
                syncAssignmentRemindersEnabled: Defaults[.syncAssignmentReminders],
                syncLiveActivityEnabled: Defaults[.syncLiveActivity],
                isCurrent: isCurrent,
                recordSent: { sent = $0 }
            )
            guard written, isCurrent() else { return false }
            NotificationSettingsSync.recordPushed(local, fields: sent)
            if NotificationSettingsSync.canClearPendingMarker(
                written: written,
                sent: local,
                current: .init(from: preferences)
            ) {
                Defaults[.notificationSettingsPushPending] = false
                return true
            }
        } catch {
            AppLogger.sync.error(
                "pushNotificationSettings failed: \(error.localizedDescription, privacy: .private)"
            )
        }
        return false
    }

    @discardableResult
    func reconcile(
        onSettled: (@MainActor () -> Void)? = nil,
        snapshot: NotificationSettingsSync.DocumentSource = .read,
        linksBeforeSnapshot: Int = 0
    ) -> Task<Void, Never> {
        NotificationSettingsPushQueue.enqueueReconcile { [weak self] isCurrent in
            guard let self, Defaults[.cloudSyncEnabled] else { return false }
            guard await self.authTokenManager.isLoggedIn, isCurrent() else { return false }

            let atm = self.authTokenManager
            let client = SettingsDocumentClient(
                authHeaderProvider: { await atm.authorizationHeader() }
            )
            do {
                let outcome = try await NotificationSettingsSync.reconcile(
                    store: self.preferences,
                    client: client,
                    cloudSyncEnabled: Defaults[.cloudSyncEnabled],
                    syncAssignmentRemindersEnabled: Defaults[.syncAssignmentReminders],
                    syncLiveActivityEnabled: Defaults[.syncLiveActivity],
                    isPushPending: { Defaults[.notificationSettingsPushPending] },
                    isCurrent: isCurrent,
                    source: NotificationSettingsPushQueue.source(snapshot, linksBeforeSnapshot: linksBeforeSnapshot),
                    recordSynced: { NotificationSettingsSync.recordSynced($0, sections: $1) }
                )
                switch outcome {
                case .settled:
                    onSettled?()
                case .deferredToPendingPush:
                    self.retryUnacknowledged()
                    return true
                case .skipped, .abandoned:
                    break
                }
            } catch {
                AppLogger.sync.error(
                    "reconcileNotificationSettings failed: \(error.localizedDescription, privacy: .private)"
                )
            }
            return false
        }
    }

    func schedulePush() {
        Defaults[.notificationSettingsPushPending] = true
        NotificationSettingsPushQueue.debounce { [weak self] in
            self?.enqueuePush()
        }
    }

    func enqueuePush() {
        NotificationSettingsPushQueue.enqueuePush { [weak self] isCurrent in
            await self?.push(isCurrent: isCurrent) ?? false
        }
    }

    func retryUnacknowledged() {
        guard Defaults[.cloudSyncEnabled] else { return }
        guard Defaults[.notificationSettingsPushPending] else { return }
        enqueuePush()
    }

    /// A device switch turned back on takes the server's section: the section's values here become
    /// the synced copy, so a push sends only what is edited after, and a reconcile adopts the rest.
    func adoptSection(_ section: NotificationSettingsSync.OwnedSection) {
        NotificationSettingsSync.sectionTurnedOn(section, local: .init(from: preferences))
        reconcile()
    }

    func cancelPushes() {
        NotificationSettingsPushQueue.cancelAll()
        Defaults[.notificationSettingsPushPending] = false
        Defaults[.notificationSettingsSyncedPreferences] = nil
        Defaults[.notificationSettingsPushSendsEveryField] = false
    }
}
#endif
