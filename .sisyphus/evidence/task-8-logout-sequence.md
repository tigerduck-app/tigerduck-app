# Logout Event Chain Audit

## AppState.logoutNTUST() sequence
- Cancels `syncTask`, `pendingRefreshTask`, and `boundaryRefreshTask`, then nils them out.
- Calls `authService.logout()` first.
- Clears user-scoped files via `DataCache.shared.clearUserScopedData()`.
- Ends Live Activity, cancels reminder requests, and posts `dataDidUpdate` inside a `Task { @MainActor in ... }`.

## AuthService.logout() sequence
- Deletes NTUST student/password keychain items.
- Fires `Task { await MoodleTokenService.shared.clearToken() }`.
- Invalidates the shared NTUST session.
- Clears auth error state and bumps `loginGeneration`.

## Moodle token clear paths
1. Fresh-install purge in `AppState.init()` deletes `moodleToken` and `moodlePrivateToken`.
2. `AuthService.logout()` calls `MoodleTokenService.shared.clearToken()` fire-and-forget.
3. `MoodleTokenService.clearToken()` deletes both Moodle token keychain entries on the main actor.

## DataCache interaction
- `DataCache.clearUserScopedData()` is still called during logout.
- It removes cache/persistent user-scoped files only; it does not touch credentials.

## Verdict
COMPLETE — the logout cascade is intact, the three Moodle token clear paths exist, and no sequence change was required.
