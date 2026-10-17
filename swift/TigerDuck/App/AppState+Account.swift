// Account state: NTUST school system login gating, library login and the widget deep-link
// drain. One file because `logoutNTUST` ties them together: it unwinds sync, push and cached
// course state in one place, next to the flags it clears.

import SwiftUI
import SwiftData
import Defaults
import os

extension AppState {

    var isNTUSTLoggedIn: Bool { authService.isNTUSTAuthenticated }

    /// Canonical gating decision for screens behind the NTUST school system.
    /// Protected screens render this state instead of deriving it from
    /// ``isNTUSTLoggedIn``, which turns `false` as soon as the session cookies
    /// expire, even when the keychain still holds credentials and the next fetch
    /// will re-authenticate silently. Gating on ``hasStoredCredentials`` keeps cached
    /// content on screen during a silent re-auth and reserves the interactive login
    /// prompt for users who have nothing stored.
    func ntustProtectedAccessState(isEmpty: Bool) -> NTUSTProtectedAccessState {
        if !authService.hasStoredCredentials { return .loginRequired }
        return isEmpty ? .empty : .content
    }

    /// Pass-through so views can surface silent re-auth failures without
    /// reaching into ``authService`` directly.
    var ntustReauthErrorMessage: String? { authService.reauthErrorMessage }

    func clearNTUSTReauthError() {
        authService.clearReauthError()
    }

    /// Entry point for any surface that wants to funnel the user into the
    /// NTUST SSO login flow. Idempotent — repeated calls while the sheet is
    /// already up no-op.
    func presentNTUSTLogin() {
        guard !isShowingNTUSTLoginSheet else { return }
        isShowingNTUSTLoginSheet = true
    }

    func dismissNTUSTLogin() {
        isShowingNTUSTLoginSheet = false
    }


    func openFromWidget(_ destination: WidgetDestination) {
        pendingWidgetDestination = destination
    }

    func clearPendingWidgetDestination() {
        pendingWidgetDestination = nil
    }

    var isLibraryLoggedIn: Bool {
        _ = _libraryRevision
        return LibraryService.hasAccount
    }

    var libraryUsername: String? {
        _ = _libraryRevision
        return LibraryService.storedUsername
    }

    /// `@MainActor` because `LibraryService.clearCredentials` is now
    /// MainActor-isolated (it sync-broadcasts to the watch). The only
    /// caller is a SwiftUI logout button, which is already on main.
    @MainActor
    func logoutLibrary() {
        LibraryService.clearCredentials()
        _libraryRevision += 1
    }

    /// Full NTUST logout: cancel any in-flight background sync, invalidate
    /// credentials, end the Live Activity and purge user-scoped caches, so the
    /// next login (possibly another user) never inherits this state on the lock
    /// screen or in notifications.
    ///
    /// `syncTask` is cancelled first: `AppServiceBridge` and the `backgroundSync`
    /// finalize block check `Task.isCancelled` before writing, so they abort
    /// instead of racing the cache purge and restoring the previous user's data.
    @discardableResult
    func logoutNTUST() -> Task<Void, Never> {
        stopRevisionPolling()
        _lastKnownRevision = 0
        syncTask?.cancel()
        syncTask = nil
        AppServiceBridge.cancelAssignmentRound()
        #if os(iOS)
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        boundaryRefreshTask?.cancel()
        boundaryRefreshTask = nil
        #endif

        let departingStudentId = authService.storedStudentId
        authService.logout()
        // A library or school mail account signed in as this student goes with it, the mail's
        // checks and notifications too; another student's stays.
        if let departingStudentId, LibraryService.clearCredentials(ifSchoolAccount: departingStudentId) {
            _libraryRevision += 1
        }
        #if os(iOS)
        if let departingStudentId { MailAccountManager.shared.logout(ifSchoolAccount: departingStudentId) }
        #endif
        // The session ends now. Only the device's unregister below still goes out as the departing
        // account, with the token this hands back; without it the device keeps getting that
        // account's reminders.
        let endingSession = Task { await authTokenManager.endSession() }
        // The tracker is process-wide and outlives the account. Without a reset the next
        // account inherits the departing user's last good sync, and the header dot shows
        // green before anything has synced.
        ServerStatusTracker.shared.reset()
        Defaults[.schoolDataSyncedAt] = nil
        // The next account opens the class table on the newest term, not on this one's pick, and
        // the empty-classroom finder on its own building.
        Defaults[.classTableSelectedSemester] = nil
        Defaults[.emptyClassroomBuilding] = nil
        // Drop the Mac skip-login bypass too; otherwise a Mac user who
        // skipped, then logged in, then logged out, would stay in
        // `MacContentView` instead of returning to `MacLoginView`.
        didSkipMacLogin = false
        // The downloaded files go with the cache below; a download still running would only
        // be thrown away once it ends.
        MoodleFileDownloads.shared.cancelAll()
        DataCache.shared.clearUserScopedData()
        // The colours held in memory went with the file only when a class table reloaded, and
        // the next account's first colour write would save the departing account's whole map.
        TigerDuckTheme.reload()
        ImportedClassTableStore.shared.removeAll()
        BulletinsViewModel.forgetListSession()
        // Unresolved conflicts come from the departing account's data; resolving one would write
        // its server marks into the next account's caches, or upload its own to that account.
        syncConflicts = []
        pendingSyncServerArchived = []
        pendingSyncServerCompleted = []
        reenableConflict = nil
        Self.forgetSyncProgress()
        pushCoordinator.forgetUploads()
        // Holiday choices are account-scoped but live in UserDefaults, out of reach of
        // `clearUserScopedData`. Cancel the queue first, or a link still waiting to run
        // sends the departing user's toggle over the next account's session.
        cancelHolidayUploads()
        AcademicCalendarStore.shared.forgetHolidayOverrides()
        // Same hazard, same fix, for the notification-settings push queue:
        // a queued write or a pending marker set by the departing account
        // must not land on — or be inherited by — whoever signs in next.
        #if os(iOS)
        cancelNotificationSettingsPushes()
        #endif
        // Signing out turns "Sync course information" off through the preference, so the change
        // runs its usual course, but its PATCH finds no session: the server would take it as the
        // account turning sync off and delete its synced data when no other device syncs it.
        cloudSyncEnabled = false
        // Before the network calls below, which offline run until they time out: the widgets
        // show the departing account's timetable until this rewrites their snapshot.
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        // Every sign-in waits for this, so none of it lands on the session that sign-in starts.
        return authService.startSignOutCalls { [self] in
            await cloudSyncCoordinator.settleForSignOut()
            await authTokenManager.unregisterDeparting(accessToken: await endingSession.value) {
                await pushCoordinator.disable()
            }
            #if os(iOS)
            await liveActivityCoordinator.endAll()
            #endif
        }
    }

    /// Whether a launch sends the unregister a sign-out left unsent: past onboarding, as no launch
    /// reaches the backend before it, and signed out. Signed in, that account's backend sign-in
    /// drops what it would send, and sent beside that sign-in it could revoke its session.
    nonisolated static func retriesDepartingUnregister(onboarded: Bool, signedIn: Bool, sessionKept: Bool) -> Bool {
        onboarded && !signedIn && sessionKept
    }

    /// ``signOutDeletesUnsyncedData(_:cloudSyncEnabled:switchedOn:synced:pendingChecks:unsent:)``
    /// for what this device holds now.
    func signOutDeletesUnsyncedData() async -> Bool {
        let cache = DataCache.shared
        let calendar = AcademicCalendarStore.shared
        let held = SignOutData(
            courses: !cache.loadUserAddedCourses().isEmpty || !cache.loadDeletedCourseNos().isEmpty,
            courseNames: cache.loadCourseCustomNames().values.contains { !$0.isEmpty },
            courseColors: !cache.loadPickedCourseColors().isEmpty,
            assignmentMarks: !cache.loadArchivedAssignmentIds().isEmpty
                || !cache.loadLocallyCompletedAssignmentIds().isEmpty,
            ignoredCourses: !cache.loadIgnoredAssignmentCourses().isEmpty,
            holidays: !calendar.optedInHolidayIDs.isEmpty
        )
        let unsent = await cloudSyncCoordinator.holdsUnsentEdits() || !pendingOverrides.isEmpty
            || !calendar.unacknowledgedHolidayIDs.isEmpty
        return Self.signOutDeletesUnsyncedData(
            held,
            cloudSyncEnabled: cloudSyncEnabled,
            switchedOn: Self.switchedOnCategories(),
            synced: Defaults[.categoriesSyncedOnce],
            pendingChecks: Defaults[.pendingConflictCategories],
            unsent: unsent
        )
    }

    /// The user's own data on this device that a sign-out deletes, by kind.
    nonisolated struct SignOutData {
        /// Courses added by hand or hidden from the class table.
        var courses = false
        var courseNames = false
        /// Colours the user picked: a generated one comes back with its course.
        var courseColors = false
        /// Assignments marked done or ignored.
        var assignmentMarks = false
        /// Courses whose assignments are all ignored.
        var ignoredCourses = false
        /// Holidays with class reminders kept on.
        var holidays = false
    }

    /// Whether a sign-out deletes data TigerSync does not keep, which its confirmation names. A
    /// category is kept with TigerSync on, its switch on, its data taken by a full sync here
    /// (`hasSynced`) and no re-enable check holding it back. Ignored courses need Assignments and
    /// Courses both, holiday choices TigerSync alone, and edits still on their way up (`unsent`)
    /// are lost however the switches stand.
    nonisolated static func signOutDeletesUnsyncedData(
        _ data: SignOutData,
        cloudSyncEnabled: Bool,
        switchedOn: Set<String>,
        synced: Set<String>,
        pendingChecks: Set<String>,
        unsent: Bool
    ) -> Bool {
        let kept = cloudSyncEnabled ? switchedOn.intersection(synced).subtracting(pendingChecks) : []
        let needs: [(held: Bool, categories: Set<String>)] = [
            (data.courses, ["courses"]),
            (data.courseNames, ["course_names"]),
            (data.courseColors, ["course_colors"]),
            (data.assignmentMarks, ["assignments"]),
            (data.ignoredCourses, ["assignments", "courses"]),
        ]
        return unsent || (data.holidays && !cloudSyncEnabled)
            || needs.contains { $0.held && !$0.categories.isSubset(of: kept) }
    }

    /// Forgets how far the departing account's sync got on this device, which lives in `Defaults`,
    /// out of reach of `clearUserScopedData`. A re-enable check left pending would keep the next
    /// account's pulls off the categories it names and hold the account's marks and course settings
    /// until a Settings visit ran it, on a device the sign-out emptied: Keep Local there clears the
    /// account's marks on the server. Until a sync of the next account takes a category, nothing
    /// marks that category for the check (`hasSynced`).
    static func forgetSyncProgress() {
        Defaults[.pendingConflictCategories] = []
        Defaults[.assignmentMarksSyncedOnce] = false
        Defaults[.lastSeenCoursesResetAt] = nil
        Defaults[.categoriesSyncedOnce] = []
        Defaults[.courseRowIdsSeen] = [:]
    }

    func notifyLibraryStateChanged() {
        _libraryRevision += 1
    }
}
