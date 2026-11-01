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
    func push(stillQueued: @escaping @MainActor () -> Bool = { true }) async -> NotificationSettingsPushQueue.PushResult {
        guard Defaults[.cloudSyncEnabled] else { return .unsettled }
        let signIn = await AccountSession.school.startingSignIn
        guard await authTokenManager.isLoggedIn, stillQueued() else { return .unsettled }

        let client = SettingsDocumentClient(auth: authTokenManager.backendAuth, for: signIn)
        let local = NotificationSettingsSync.LocalPreferences(from: preferences)
        var sent: [String: Any] = [:]
        do {
            let result = try await NotificationSettingsSync.push(
                local: local,
                base: NotificationSettingsSync.pushBase(local: local),
                client: client,
                cloudSyncEnabled: Defaults[.cloudSyncEnabled],
                syncAssignmentRemindersEnabled: Defaults[.syncAssignmentReminders],
                syncLiveActivityEnabled: Defaults[.syncLiveActivity],
                isCurrent: stillQueued,
                recordOnServer: { sent = $0 }
            )
            guard result == .landed, stillQueued() else { return .unsettled }
            NotificationSettingsSync.mergeSentFields(sent, of: local, for: signIn)
            if NotificationSettingsSync.canClearPendingMarker(
                result,
                sent: local,
                current: .init(from: preferences)
            ) {
                Defaults[.notificationSettingsPushPending, for: signIn] = false
                return .landedWithNothingLeft
            }
        } catch {
            AppLogger.sync.error(
                "pushNotificationSettings failed: \(error.localizedDescription, privacy: .private)"
            )
        }
        return .unsettled
    }

    @discardableResult
    func reconcile(
        onSettled: (@MainActor () -> Void)? = nil,
        snapshot: NotificationSettingsSync.DocumentSource = .read,
        linksBeforeSnapshot: Int = 0
    ) -> Task<Void, Never> {
        NotificationSettingsPushQueue.enqueueReconcile { [weak self] stillQueued in
            guard let self, Defaults[.cloudSyncEnabled] else { return .finished }
            let signIn = await AccountSession.school.startingSignIn
            guard await self.authTokenManager.isLoggedIn, stillQueued() else { return .finished }

            let client = SettingsDocumentClient(auth: self.authTokenManager.backendAuth, for: signIn)
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
                    recordSynced: { NotificationSettingsSync.recordSyncedSections($1, of: $0, for: signIn) }
                )
                switch outcome {
                case .settled:
                    onSettled?()
                case .deferredToPendingPush:
                    self.retryUnacknowledged()
                    return .deferredToPendingPush
                case .skipped, .abandoned:
                    break
                }
            } catch {
                AppLogger.sync.error(
                    "reconcileNotificationSettings failed: \(error.localizedDescription, privacy: .private)"
                )
            }
            return .finished
        }
    }

    func schedulePush() {
        Defaults[.notificationSettingsPushPending, for: AccountSession.school.currentSignIn] = true
        NotificationSettingsPushQueue.debounce { [weak self] in
            self?.enqueuePush()
        }
    }

    func enqueuePush() {
        NotificationSettingsPushQueue.enqueuePush { [weak self] stillQueued in
            await self?.push(stillQueued: stillQueued) ?? .unsettled
        }
    }

    func retryUnacknowledged() {
        guard Defaults[.cloudSyncEnabled] else { return }
        guard Defaults[.notificationSettingsPushPending] else { return }
        enqueuePush()
    }

    func adoptSection(_ section: NotificationSettingsSync.OwnedSection, for signIn: SignIn) {
        NotificationSettingsSync.sectionTurnedOn(section, local: .init(from: preferences), for: signIn)
        reconcile()
    }

    func deviceSwitchChanged(_ section: NotificationSettingsSync.OwnedSection, old: Bool, new: Bool, for signIn: SignIn) {
        if NotificationSettingsSync.shouldAdoptOnDeviceSwitchChange(old: old, new: new) { adoptSection(section, for: signIn) }
    }

    func cancelPushes() {
        NotificationSettingsPushQueue.cancelAll()
        Defaults.reset(.notificationSettingsPushPending)
        NotificationSettingsSync.forget()
    }
}
#endif
