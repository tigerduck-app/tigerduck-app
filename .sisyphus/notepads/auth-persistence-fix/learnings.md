# Learnings — auth-persistence-fix

## [2026-04-20] Session Start
- Plan: 12 tasks (T0→T8 + F1-F4)
- Critical path: T0 → T1a/T1b/T1c/T1d/T1e → T3 → T5 → T6 → T7 → F1-F4
- T0 is a HARD GATE: if probe fails (non-PASS, non-FAIL-CREDENTIAL), plan halts
- Credentials: NTUST_USER and NTUST_PASS are in environment variables
- Build command: xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuck -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
- NO simulator runs, NO new tests, NO backend changes
- All commits must be GPG signed, no Co-Authored-By

---

## T1a: MoodleService Inventory (2026-04-21)

### Key Findings

**MoodleService.swift is a single-function service (131 lines):**
- Only public API: `MoodleService.fetchAssignments(session:studentId:password:)`
- 3 network calls total: 2x GET `moodle2.ntust.edu.tw/login/index.php` (sesskey scrape) + 1x POST `/lib/ajax/service.php`
- The POST endpoint IS `core_calendar_get_action_events_by_timesort` — already using the correct webservice function name

**Auth flow:**
- Checks `NTUSTSessionManager.shared.cookiesValid` first
- Falls back to `SSOLoginService.ensureServiceLogin(serviceURL: moodleLoginURL)` if cookies invalid
- Sesskey is scraped from HTML — required prerequisite for the AJAX endpoint
- On sesskey miss: re-authenticates and retries once

**SSOLoginService has zero Moodle-specific logic:**
- Only Moodle reference is a comment about preserving Moodle cookies during SSO re-auth
- `ssoam2.ntust.edu.tw` cookies cleared; `moodle2.ntust.edu.tw` cookies preserved intentionally

**Consumer chain:**
```
CalendarViewModel → KMPServiceBridge.fetchAssignments() → MoodleService.fetchAssignments()
HomeViewModel → KMPServiceBridge.fetchAssignments() → MoodleService.fetchAssignments()
```

**Task 6 deletion scope:** Entire `MoodleService.swift` (131 lines). `KMPServiceBridge.fetchAssignments()` (lines 146–171) needs updating to call replacement. `CalendarViewModel` unchanged if bridge interface stays same.

**Gotcha:** Assignment data comes from calendar events filtered by `modulename == "assign"`, NOT from `mod_assign_get_assignments`. Switching to the dedicated assign endpoint would require token-based auth (different flow).

## [2026-04-21] T1b: isNTUSTLoggedIn Call-Graph Discovery

### Findings
- `isNTUSTLoggedIn` has exactly **2 callers** in the codebase (outside its own definition):
  1. `SettingsView.swift:281` — `isLoggedIn: appState.isNTUSTLoggedIn` → **MIGRATE_TO_hasStoredCredentials** (T2 target)
  2. `NTUSTLoginSheetHost.swift:28` — `if appState.isNTUSTLoggedIn {` → **KEEP** (post-login success check)

### Key Insight: NTUSTLoginSheetHost is KEEP, not MIGRATE
- The login sheet checks `isNTUSTLoggedIn` *immediately after* `authService.login()` returns
- At that point, cookie-based truth is correct: we want to know if login actually succeeded
- `hasStoredCredentials` would be wrong here — credentials could be stale/pre-existing
- This is a post-action verification, not a UI gating decision

### isNTUSTAuthenticated is NOT directly called outside AppState
- `authService.isNTUSTAuthenticated` is only consumed via `AppState.isNTUSTLoggedIn`
- No direct callers in feature code — the pass-through is the only access point

### AGENTS.md Anti-Pattern Confirmed
- `swift/TigerDuck/AGENTS.md:39` explicitly states: "Do not re-derive NTUST protected access from `isNTUSTLoggedIn` alone; use `ntustProtectedAccessState(isEmpty:)`"
- SettingsView.swift:281 violates this for the login-state display (not access gating, but still cookie-volatile)

### T2 Scope is Minimal
- Only 1 file needs changing: `SettingsView.swift:281`
- Change: `appState.isNTUSTLoggedIn` → `appState.authService.hasStoredCredentials`

## T1d: Test Impact Analysis (2026-04-21)

- **4 test files** found across `TigerDuckTests` and `TigerDuckUITests`
- **0 affected** — no test file references `AuthService`, `MoodleService`, `NTUSTSessionManager`, `isNTUSTLoggedIn`, or `isNTUSTAuthenticated`
- `TimeSliderViewModelTests.swift` is fully safe; only uses `TimeSliderViewModel`, `TimeSliderMetrics`, `CourseTimeSlot`, `SDCourse`
- **Conclusion: NO_TESTS_AFFECTED** — auth-persistence-fix changes require no test modifications
- Evidence written to `.sisyphus/evidence/test-impact.md`

## [T1e] GPG Pre-flight Results (2026-04-21)
- GPG key D4FDC6CA456096D4 (ed25519) confirmed in keyring, uid: xinshoutw <me@xinshou.tw>
- commit.gpgsign=true confirmed in git config
- Test sign (echo "probe" | gpg --clearsign) → SUCCESS
- Last 5 commits all carry valid GPG signatures (git log --format='%G?' → G G G G G)
- Commit format observed: `type(scope): short description` — matches CLAUDE.md spec
- Evidence: .sisyphus/evidence/gpg-preflight-ok.md + commit-format-spec.md
- Status: READY FOR COMMITS

---

## T1c: Widget / LiveActivity Moodle Coupling Audit (2026-04-21)

**Conclusion: NO_COUPLING**

Key findings:
- `TigerDuckLiveActivity` widget extension has **zero** Keychain/Moodle/auth access
- Widget is a pure renderer of `LiveActivitySnapshot` (pre-computed struct from app side)
- `LiveActivityScenarioResolver.swift` references `assignment.moodleDeepLink` — a URL string field, NOT a credential
- No `moodleToken` key exists in `AppConstants.KeychainKeys` (planned T4 addition)
- Current Moodle auth uses session cookies, not a stored persistent token

**Implication for T4 (moodleToken Keychain key):**
- `moodleToken` can use **app-only** Keychain key — no shared access group needed
- Recommended: `static let moodleToken = "moodle_token"` in `AppConstants.KeychainKeys`
- Caveat: `SecureStore.save()` currently dual-writes to both `shared` and `sharedGroup` unconditionally; for truly app-only storage, call `shared.setObject(...)` directly

**SecureStore architecture:**
- `shared` = app-only Valet (`Identifier("org.ntust.app.TigerDuck")`)
- `sharedGroup` = shared group Valet (`group.org.ntust.app.TigerDuck`)
- Both app and widget extension have the same App Group entitlement, but widget never reads Keychain

## T4: Moodle keychain constants + fresh-install purge (2026-04-21)
- Added `AppConstants.KeychainKeys.moodleToken` and `moodlePrivateToken` as static string literals.
- Added `AppConstants.moodleBaseURL` for `https://moodle2.ntust.edu.tw`.
- Fresh-install purge now clears both Moodle Keychain entries alongside existing NTUST/library keys.
- `xcodebuild build` passed; current build still emits pre-existing MoodleTokenService Swift 6 isolation warnings.

## T3: Moodle token actor scaffold (2026-04-21)
- Added `MoodleWebserviceError` with six explicit cases and JSON `errorcode` parsing for Moodle error bodies.
- Added `MoodleTokenService` as an `actor` with shared singleton plus separate in-flight guards for obtain vs refresh paths.
- Used an ephemeral `URLSession` with 15s timeout and `URLComponents` URL/body construction to avoid cookie interference and string-built endpoints.
- `KeychainManager` accesses in this service must hop through `MainActor.run` under Swift 6 isolation checks.
- Until centralized constants are wired in, Moodle token keys remain local snake_case literals: `moodle_token` and `moodle_private_token`.

- AuthService login success can chain cross-service best-effort token work after keychain persistence as long as each integration is isolated in its own do/catch and never changes the NTUST login result.
- AuthService logout can clear actor-owned auth state with fire-and-forget `Task { await ... }` immediately after credential deletion, preserving logout responsiveness and existing loginGeneration semantics.

## T5b: Migrations compatibility layer (2026-04-21)
- Created `Services/Migrations/` with a local AGENTS contract; the folder doc explicitly reserves breaking-change compatibility code for this layer only.
- `MoodleTokenMigration.runIfNeeded()` stays self-contained and idempotent via `Defaults[.moodleTokenMigrationDone]`; failure stays silent and intentionally leaves the flag unset for retry-on-next-launch behavior.
- Migration-side keychain reads need `MainActor.run` to align with the same Swift 6 isolation pattern already used inside `MoodleTokenService`.
- `AppState` is now the sole trigger point through `runPendingMigrations()` at the end of `init()`, keeping AuthService and Moodle token services free of migration references.

## T6: MoodleService REST rewrite (2026-04-21)
- `MoodleService.fetchAssignments(session:studentId:password:)` can keep its public signature while ignoring legacy credentials and sourcing auth exclusively from `MoodleTokenService.shared`.
- The Moodle calendar webservice works cleanly with a plain GET to `/webservice/rest/server.php` using `wstoken`, `wsfunction=core_calendar_get_action_events_by_timesort`, `moodlewsrestformat=json`, `limitnum`, and `timesortfrom` via `URLComponents`.
- Treat `invalidtoken` and `accessexception` as a single recovery path: `clearToken()`, then `refreshTokenIfNeeded()`, then retry the webservice call exactly once.
- The assignment mapping can stay compatible by filtering `modulename == "assign"`, preserving course-name extraction, and falling back to `timeusermidnight` when `timestart` is absent.

- `xcodebuild build` now passes after routing assignment fetches through `Bridge/MoodleAssignmentBridgeService`, which keeps the bridge buildable without introducing migration coupling into feature services.

## [T8] Logout cascade + DataCache verification (2026-04-21)
- Logout order is still: cancel sync tasks → `authService.logout()` → `DataCache.clearUserScopedData()` → Live Activity/reminder cleanup.
- The three Moodle token clear paths are present: fresh-install purge, `AuthService.logout()` fire-and-forget hook, and `MoodleTokenService.clearToken()` actual deletion.
- `DataCache.clearUserScopedData()` remains logout-only cache cleanup; it does not overlap with keychain credential deletion.
- Build verification returned `EXIT:0`.

## T7: Consumer ViewModel Verification (2026-04-21)

- `KMPServiceBridge` does NOT call `MoodleService` directly; it calls `MoodleAssignmentBridgeService.fetchAssignments` (bridge layer in `swift/TigerDuck/Bridge/`)
- `MoodleAssignmentBridgeService` has the SAME public API signature as `MoodleService.fetchAssignments`: `(session:studentId:password:) async throws -> [SDAssignment]`
- `CalendarViewModel` only calls `KMPServiceBridge.fetchAssignments`, never touches MoodleService
- `loginGeneration` race guard: 5 matches in KMPServiceBridge (snapshot at lines 24, 151; post-check at lines 138, 167; comment at 165)
- xcodebuild exit 0, no errors after MoodleService refactor
- **C5 commit NOT needed** — no API surface changed for consumers
