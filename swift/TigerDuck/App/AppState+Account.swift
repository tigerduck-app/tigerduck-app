// Account state and session transitions — split out of AppState.swift.
//
// NTUST (校務系統) login gating, library login, and the widget deep-link
// drain. Grouped because logout is the thing that ties them together:
// `logoutNTUST` has to unwind sync, push, and cached course state in one
// place, and it reads more clearly next to the flags it clears.

import SwiftUI
import SwiftData
import Defaults
import os

extension AppState {

    var isNTUSTLoggedIn: Bool { authService.isNTUSTAuthenticated }

    /// Canonical gating decision for 校務系統-protected surfaces. Protected
    /// screens render this state instead of re-deriving from
    /// ``isNTUSTLoggedIn``. The difference matters: ``isNTUSTLoggedIn``
    /// flips to `false` the moment session cookies TTL, even when the
    /// keychain still holds credentials and the next fetch will silently
    /// re-authenticate. Gating on ``hasStoredCredentials`` implements the
    /// cached-first UX — cached content keeps rendering during a silent
    /// re-auth, and the interactive login prompt is reserved for users
    /// who truly have nothing stored.
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
    /// credentials, tear down the Live Activity, cancel pending assignment
    /// reminders, and purge user-scoped caches so a subsequent login (possibly
    /// a different user) never inherits previous state on the lock screen or
    /// in notifications.
    ///
    /// `syncTask` is cancelled first so that `AppServiceBridge` and the
    /// `backgroundSync` finalize block — both of which check
    /// `Task.isCancelled` before writing — abort cleanly rather than racing
    /// the cache purge below and resurrecting the previous user's data.
    func logoutNTUST() {
        stopRevisionPolling()
        _lastKnownRevision = 0
        syncTask?.cancel()
        syncTask = nil
        #if os(iOS)
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        boundaryRefreshTask?.cancel()
        boundaryRefreshTask = nil
        #endif

        authService.logout()
        Task { await authTokenManager.logout() }
        // Drop the Mac skip-login bypass too; otherwise a Mac user who
        // skipped, then logged in, then logged out, would stay in
        // `MacContentView` instead of returning to `MacLoginView`.
        didSkipMacLogin = false
        DataCache.shared.clearUserScopedData()
        Task { @MainActor in
            await cloudSyncCoordinator.disable()
            await pushCoordinator.disable()
            #if os(iOS)
            await liveActivityCoordinator.endAll()
            await reminderScheduler.cancelAllOwnedRequests()
            #endif
            NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        }
    }

    func notifyLibraryStateChanged() {
        _libraryRevision += 1
    }
}
