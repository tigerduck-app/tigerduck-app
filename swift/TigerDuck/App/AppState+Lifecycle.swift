// One-shot entry points, kept apart from the per-poll and per-toggle AppState+ files:
// `runPendingMigrations` from `init()`, `startCloudSyncIfEnabled` when the root scene
// first appears (each platform's own `.onAppear`), `completeOnboarding` after onboarding.

import SwiftUI
import Defaults

extension AppState {

    // MARK: - Migrations

    /// Trigger all pending one-time compatibility migrations.
    /// Called once per app launch from init(). Everything that can wait runs
    /// in a detached background task so it never blocks the main thread or app
    /// startup.
    func runPendingMigrations() {
        // Cache-deleting migrations run synchronously, ahead of the task below. Once init()
        // returns, `backgroundSync()` may write fresh caches, and deleting them after its
        // warm pass leaves the grids blank. Each is a cheap doneKey-guarded one-shot.
        ClassroomAbbrCacheMigration.runIfNeeded()
        CustomNameCacheMigration.runIfNeeded()
        SemesterAttributionCacheMigration.runIfNeeded()
        #if os(iOS)
        // Inline because it costs three UserDefaults reads, not for order: the preferences it
        // repairs are read as each register request is built, so a late write self-heals.
        // iOS only: a Mac has no bulletin push, so it never wrote the ambiguous flag state.
        BulletinPushOptOutMigration.runIfNeeded()
        // Synchronous because `configuredTabs` was read before init() got here: a bar it
        // keeps is reloaded before the tab bar or What's New reads it. iOS only, like the
        // bar itself; the Mac sidebar keeps its own list.
        if DefaultTabsPinMigration.runIfNeeded() {
            configuredTabs = AppState.decodeConfiguredTabs(Defaults[.configuredTabsData]) ?? AppFeature.defaultTabs
        }
        #endif
        Task(priority: .utility) { @MainActor in
            #if os(iOS)
            // First, because it is purely local: it must not wait behind the Moodle
            // migration's network refresh while the reminders it removes are queued to fire.
            // iOS only and off the macOS allow-list: no Mac ever scheduled `LA-reminder-*`.
            await PendingReminderPurgeMigration.runIfNeeded()
            // Not in the macOS allow-list either. It queues and returns: the
            // routine runs on the notification-settings push queue.
            NotificationSettingsSeedMigration.runIfNeeded { onSettled in
                self.reconcileNotificationSettings(onSettled: onSettled)
            }
            #endif
            await MoodleTokenMigration.runIfNeeded()
            HomeSectionTitleMigration.runIfNeeded()
            // Add future migrations here in sequence. Anything that deletes
            // cached data belongs above the task, not in it.
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
        // A fresh install registers its device here, not in `init`, so nothing reaches the
        // push server before this point. Not iOS-gated: macOS gets here via `MacLoginView`,
        // and gating would leave a fresh Mac install unregistered until its second launch.
        pushCoordinator.enable()
        backgroundSync()
    }

}
