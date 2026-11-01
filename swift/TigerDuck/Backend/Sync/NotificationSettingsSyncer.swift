#if os(iOS)
import Defaults
import Foundation
import os

@MainActor
final class NotificationSettingsSyncer {
    private let authTokenManager: AuthTokenManager
    private let preferences: LiveActivityPreferencesStore

    init(authTokenManager: AuthTokenManager, preferences: LiveActivityPreferencesStore) {
        self.authTokenManager = authTokenManager
        self.preferences = preferences
    }


    @discardableResult
    func push(stillQueued: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        guard Defaults[.cloudSyncEnabled] else { return false }
        let signIn = await AccountSession.school.startingSignIn
        guard await authTokenManager.isLoggedIn, stillQueued() else { return false }

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
                isCurrent: stillQueued,
                recordSent: { sent = $0 }
            )
            guard written, stillQueued() else { return false }
            NotificationSettingsSync.recordPushed(local, fields: sent, for: signIn)
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
        NotificationSettingsPushQueue.enqueueReconcile { [weak self] stillQueued in
            guard let self, Defaults[.cloudSyncEnabled] else { return false }
            let signIn = await AccountSession.school.startingSignIn
            guard await self.authTokenManager.isLoggedIn, stillQueued() else { return false }

            let atm = self.authTokenManager
            let client = SettingsDocumentClient(
                authHeaderProvider: { await atm.authorizationHeader() }
            )
            do {
                let outcome = try await NotificationSettingsReconcile.reconcile(
                    store: self.preferences,
                    client: client,
                    cloudSyncEnabled: Defaults[.cloudSyncEnabled],
                    syncAssignmentRemindersEnabled: Defaults[.syncAssignmentReminders],
                    syncLiveActivityEnabled: Defaults[.syncLiveActivity],
                    isPushPending: { Defaults[.notificationSettingsPushPending] },
                    isCurrent: stillQueued,
                    source: NotificationSettingsPushQueue.source(snapshot, linksBeforeSnapshot: linksBeforeSnapshot),
                    recordSynced: { NotificationSettingsSync.recordSynced($0, sections: $1, for: signIn) }
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
        NotificationSettingsPushQueue.enqueuePush { [weak self] stillQueued in
            await self?.push(stillQueued: stillQueued) ?? false
        }
    }

    func retryUnacknowledged() {
        guard Defaults[.cloudSyncEnabled] else { return }
        guard Defaults[.notificationSettingsPushPending] else { return }
        enqueuePush()
    }

    func adoptSection(_ section: NotificationSettingsSync.OwnedSection) {
        NotificationSettingsSync.sectionTurnedOn(
            section, local: .init(from: preferences), for: AccountSession.school.currentSignIn
        )
        reconcile()
    }

    func deviceSwitchChanged(_ section: NotificationSettingsSync.OwnedSection, old: Bool, new: Bool) {
        if NotificationSettingsSync.shouldAdoptOnDeviceSwitchChange(old: old, new: new) { adoptSection(section) }
    }

    func cancelPushes() {
        NotificationSettingsPushQueue.cancelAll()
        Defaults[.notificationSettingsPushPending] = false
        NotificationSettingsSync.forget()
    }
}
#endif
