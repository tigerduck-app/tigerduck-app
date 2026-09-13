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
        #if os(iOS)
        // Synchronous like the three above, though nothing at launch reads
        // what it writes any more: registration is no longer gated on a
        // stored flag, and the two delivery preferences it repairs
        // (`bulletinPushEnabled`, `serverPushUserOptOut`) are read when a
        // register request is built — after an APNs round trip, and re-sent
        // on every later register, so a late write would self-heal anyway.
        // Kept inline because it costs three UserDefaults reads and there
        // is nothing to await. iOS only: bulletin push has no macOS surface
        // (see Features/Bulletins), so a Mac build never wrote the
        // ambiguous flag state this disambiguates.
        BulletinPushOptOutMigration.runIfNeeded()
        #endif
        Task(priority: .utility) { @MainActor in
            #if os(iOS)
            // First, because it is purely local: it must not wait behind the
            // Moodle migration's network refresh while the reminders it
            // removes are still queued to fire.
            //
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
