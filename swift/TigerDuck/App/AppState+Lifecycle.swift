import SwiftUI
import Defaults

extension AppState {

    func runPendingMigrations() {
        SemesterAttributionCacheMigration.runIfNeeded()
        SyncedAccountSeedMigration.runIfNeeded(signedIn: authService.hasStoredCredentials)
        CourseColorPickSeedMigration.runIfNeeded()
        StoredPasswordLatchRetryMigration.runIfNeeded()
        LibraryPasswordLatchRetryMigration.runIfNeeded()
        DepartingSessionListMigration.runIfNeeded()
        if CustomAccentContrastMigration.runIfNeeded() {
            accentColorHex = Defaults[.accentColorHex]
        }
        #if os(iOS)
        BulletinPushOptOutMigration.runIfNeeded()
        if DefaultTabsPinMigration.runIfNeeded() {
            configuredTabs = AppState.decodeConfiguredTabs(Defaults[.configuredTabsData]) ?? AppFeature.defaultTabs
        }
        if LibraryTabAddMigration.runIfNeeded() {
            configuredTabs = AppState.decodeConfiguredTabs(Defaults[.configuredTabsData]) ?? AppFeature.defaultTabs
        }
        LiveActivitySnapshotPurgeMigration.runIfNeeded()
        NotificationSettingsSyncedSeedMigration.runIfNeeded(
            current: .init(from: liveActivityPreferences),
            signedIn: authService.hasStoredCredentials
        )
        if FlipToLibraryDefaultOffMigration.runIfNeeded() {
            flipToLibraryEnabled = Defaults[.flipToLibraryEnabled]
        }
        #endif
        Task(priority: .utility) { @MainActor in
            #if os(iOS)
            await PendingReminderPurgeMigration.runIfNeeded()
            NotificationSettingsSeedMigration.runIfNeeded { onSettled in
                self.reconcileNotificationSettings(onSettled: onSettled)
            }
            await MoodleDownloadProtectMigration.runIfNeeded(
                root: MoodleFiles.shared.moodleFilesDir,
                isProtectedDataAvailable: UIApplication.shared.isProtectedDataAvailable
            )
            #endif
        }
    }

    func startCloudSyncIfEnabled() {
        if cloudSyncCoordinator.state == .active {
            cloudSyncCoordinator.start()
        }
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        Defaults[.hasCompletedOnboarding] = true
        pushCoordinator.enable()
        backgroundSync()
        Task { await TLSPinDocumentFetcher.shared.fetchIfDue() }
    }

}
