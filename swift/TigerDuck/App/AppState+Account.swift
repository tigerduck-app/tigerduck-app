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
        return LibraryService.isTokenValid
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
    func logoutNTUST() {
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

        authService.logout()
        Task { await authTokenManager.logout() }
        // The tracker is process-wide and outlives the account. Without a reset the next
        // account inherits the departing user's last good sync, and the header dot shows
        // green before anything has synced.
        ServerStatusTracker.shared.reset()
        Defaults[.schoolDataSyncedAt] = nil
        // The next account opens the class table on the newest term, not on this one's pick.
        Defaults[.classTableSelectedSemester] = nil
        // Drop the Mac skip-login bypass too; otherwise a Mac user who
        // skipped, then logged in, then logged out, would stay in
        // `MacContentView` instead of returning to `MacLoginView`.
        didSkipMacLogin = false
        // The downloaded files go with the cache below; a download still running would only
        // be thrown away once it ends.
        MoodleFileDownloads.shared.cancelAll()
        DataCache.shared.clearUserScopedData()
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
        // Signing out turns "Sync course information" off through the preference, like every
        // other writer, so the change runs its usual course in `cloudSyncEnabledDidChange(to:)`.
        cloudSyncEnabled = false
        // Before the network calls below, which offline run until they time out: the widgets
        // show the departing account's timetable until this rewrites their snapshot.
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        Task { @MainActor in
            await cloudSyncCoordinator.settleForSignOut()
            await pushCoordinator.disable()
            #if os(iOS)
            await liveActivityCoordinator.endAll()
            #endif
        }
    }

    /// Forgets how far the departing account's sync got on this device, which lives in `Defaults`,
    /// out of reach of `clearUserScopedData`. A re-enable check left pending would keep the next
    /// account's pulls off the categories it names and hold the account's marks and course settings
    /// until a Settings visit ran it, on a device the sign-out emptied: Keep Local there clears the
    /// account's marks on the server. Until the next account's first sync, nothing is marked for that
    /// check (`hasSyncedAccount`).
    static func forgetSyncProgress() {
        Defaults[.pendingConflictCategories] = []
        Defaults[.assignmentMarksSyncedOnce] = false
        Defaults[.lastSeenCoursesResetAt] = nil
        Defaults[.accountSyncedOnce] = false
    }

    func notifyLibraryStateChanged() {
        _libraryRevision += 1
    }
}
