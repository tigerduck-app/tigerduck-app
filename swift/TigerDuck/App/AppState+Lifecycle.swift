// One-shot lifecycle entry points — split out of AppState.swift.
//
// `runPendingMigrations` runs once from `init()`, `startCloudSyncIfEnabled`
// runs once when the root scene first appears (iOS and Mac each call it
// from their own `.onAppear`), and `completeOnboarding` runs once when the
// user finishes the onboarding flow. None of these are steady-state
// behavior, so they're grouped separately from the once-per-poll /
// once-per-toggle logic living in the other AppState+ files.

import SwiftUI
import Defaults

extension AppState {

    // MARK: - Migrations

    /// Trigger all pending one-time compatibility migrations.
    /// Called once per app launch from init(). Everything that can wait runs
    /// in a detached background task so it never blocks the main thread or app
    /// startup.
    func runPendingMigrations() {
        // Every migration that *deletes* course caches runs synchronously,
        // ahead of the task below. `backgroundSync()` fires from the scene as
        // soon as init() returns, so it can have written fresh caches by the
        // time a migration queued behind an awaited one resumes — clearing
        // them then blanks the very grids these exist to repair, with the warm
        // pass that would refill them already spent. Each is a doneKey-guarded
        // one-shot over a handful of files, and init() runs on the main actor
        // with nothing awaited ahead of it, so they always land before the
        // first sync starts.
        ClassroomAbbrCacheMigration.runIfNeeded()
        CustomNameCacheMigration.runIfNeeded()
        SemesterAttributionCacheMigration.runIfNeeded()
        Task(priority: .utility) { @MainActor in
            await MoodleTokenMigration.runIfNeeded()
            HomeSectionTitleMigration.runIfNeeded()
            #if os(iOS)
            // iOS only: `PendingReminderPurgeMigration.swift` is not in
            // project.pbxproj's `INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]`
            // allow-list (macOS excludes all *.swift by default and
            // opts specific files back in), matching the deleted
            // AssignmentReminderScheduler it cleans up after — macOS never
            // scheduled `LA-reminder-*` requests, so there is nothing for
            // it to purge, and the type is invisible to a macOS build.
            await PendingReminderPurgeMigration.runIfNeeded()
            // Not in the macOS allow-list either. It queues and returns: the
            // routine runs on the notification-settings push queue.
            NotificationSettingsSeedMigration.runIfNeeded { onSettled in
                self.reconcileNotificationSettings(onSettled: onSettled)
            }
            #endif
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
        // A fresh install registers its device here rather than in `init`,
        // so nothing reaches the push server before this point. Not
        // iOS-gated: `pushCoordinator` is cross-platform since the v3
        // backend work, and macOS reaches this through `MacLoginView`, so
        // gating here would leave a fresh Mac install unregistered until
        // its second launch.
        pushCoordinator.enable()
        backgroundSync()
    }

}
