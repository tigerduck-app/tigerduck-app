# TigerDuck Code Review — dev vs main

**Date**: 2026-06-20
**Branches**: `dev` vs `main` across all three repos

---

## Backend (`~/tigerduck-backend`)

201 files changed, 38,528 insertions(+), 279 deletions(-)

### Critical / High

**1. Portal proxies to public API on port 40000 (violates architecture constraint)**
- **Severity**: High
- **Files**: `portal/app/routes/custom_push.py`, `portal/app/routes/announcement.py`, `portal/app/routes/device_lists.py`, `portal/app/routes/devices.py`, `portal/app/routes/test_push.py`, `portal/app/status.py`
- **Description**: Every portal route proxies HTTP requests to `http://tigerduck-internal:40000/v2/...` (the public API). Project memory explicitly states the portal "must NEVER call the public 40000 API" and should read the v3 DB directly. The current architecture means the portal depends on the v2 API contract, and any v2 deprecation breaks the admin panel.
- **Fix**: Replace httpx proxy calls with direct SQLAlchemy queries against the v3 database for read paths. Evaluate write paths individually.

**2. Portal has zero application-level authentication**
- **Severity**: High
- **Files**: `portal/app/main.py` (lines 7-8, 54)
- **Description**: The portal relies entirely on an external auth proxy (e.g. Cloudflare Zero Trust). If that gate is misconfigured, bypassed, or absent (staging, direct container access), all portal endpoints are fully open — including database export/import, push dispatch, and device browsing.
- **Fix**: Add a lightweight middleware that validates a portal admin token or the `CF-Access-JWT-Assertion` header on every `/api/*` route as defense-in-depth.

**3. Database backup import endpoint has no file-size limit and no elevated auth**
- **Severity**: High
- **Files**: `portal/app/routes/backup.py` (lines 108-192)
- **Description**: Combined with finding 2, an attacker can upload an arbitrarily large file to exhaust disk, or a crafted pg_dump to replace the entire production database (`--clean --if-exists` drops and recreates all tables). Even with auth, a full DB replacement should require elevated privileges.
- **Fix**: Add `Content-Length` cap. Require a separate confirmation token for import. Consider a two-step flow (upload, then confirm after manifest review).

**4. Custom push dispatcher lacks database-level concurrency protection — double-send risk**
- **Severity**: High
- **Files**: `server/push/custom_push_dispatcher.py` (lines 33-38, 63-77)
- **Description**: Uses `asyncio.Lock()` (in-process only) instead of `FOR UPDATE SKIP LOCKED` or a PostgreSQL advisory lock. If the backend runs multiple workers or replicas, the same pending rows are selected by both and pushes are sent twice. This is the only dispatcher path lacking database-level protection (v3 pipeline and v2 dispatcher both use `FOR UPDATE SKIP LOCKED`).
- **Fix**: Add `.with_for_update(skip_locked=True)` to the `CustomPushDispatch` select query, matching `server/scheduler/dispatcher.py`.

**5. Rate limiter not applied to `/auth/refresh` endpoint**
- **Severity**: High
- **Files**: `server/routes/auth.py` (lines 64-77), `server/auth/service.py` (lines 182-233)
- **Description**: Login is rate-limited per student_id and IP, but refresh has no rate limiting. An attacker with an intercepted refresh token can hammer the endpoint at arbitrary speed, creating DB load via `SELECT ... FOR UPDATE` and potentially exhausting the grace window before the legitimate client retries.
- **Fix**: Apply a per-IP rate limit to `/auth/refresh` (e.g. 10 requests/minute).

**6. `require_shared_secret` is a silent no-op when secret is unconfigured**
- **Severity**: High
- **Files**: `server/security.py` (lines 20-21), `server/config.py` (line 39)
- **Description**: `api_shared_secret` defaults to empty string. When empty, `require_shared_secret` returns immediately, making all debug and admin endpoints (push dispatch, sync policy mutation, alert fan-out) completely unauthenticated. A production deployment that forgets this env var is wide open.
- **Fix**: Refuse to start (or loudly warn and disable the debug router) when `env=production` and `api_shared_secret` is empty.

### Medium

**7. Subscription PATCH has TOCTOU race (no CAS or FOR UPDATE)**
- **Severity**: Medium
- **Files**: `server/routes/bulletins_v3.py` (lines 125-164)
- **Description**: `patch_subscription` reads the row, checks `revision != base_revision`, mutates, and increments `revision += 1` without row locking. Two concurrent PATCHes reading the same revision both pass the check, and last-write silently wins. Compare with `settings_docs.py` which correctly uses an atomic `UPDATE ... WHERE revision = base_revision`.
- **Fix**: Use an atomic CAS `UPDATE ... WHERE revision = base_revision`, or add `.with_for_update()` to the select.

**8. Bulletin state PUT: unhandled IntegrityError on concurrent upsert**
- **Severity**: Medium
- **Files**: `server/routes/bulletins_v3.py` (lines 236-258)
- **Description**: Two concurrent requests for the same `(user_id, bulletin_id)` both see `state is None`, both try INSERT, and one hits the UniqueConstraint. No `IntegrityError` catch, so it surfaces as a 500.
- **Fix**: Wrap the INSERT in try/except `IntegrityError` and re-fetch, or use `INSERT ... ON CONFLICT DO NOTHING` + `SELECT ... FOR UPDATE`.

**9. v2 scheduler dispatcher commits after entire tick — crash loses status updates**
- **Severity**: Medium
- **Files**: `server/scheduler/dispatcher.py` (lines 70-209)
- **Description**: The entire tick (up to 64 pushes + 64 LA end-events) runs in one transaction with a single `session.commit()` at the end. If an exception occurs on the 63rd push, all 62 successfully sent pushes revert to `pending`, causing re-delivery.
- **Fix**: Commit after each send result, or at least after each batch of related operations.

**10. Custom push dispatcher: bare `session_factory()` loses mutations on exception**
- **Severity**: Medium
- **Files**: `server/push/custom_push_dispatcher.py` (lines 63, 141)
- **Description**: Uses `async with session_factory()` instead of `session_scope()`. If an exception occurs between Apple sends and the explicit `commit()`, successful Apple delivery status updates are lost and those pushes re-send on the next tick.
- **Fix**: Use `session_scope(session_factory)` or commit after each platform batch.

**11. Missing JWT `iss` and `aud` claims**
- **Severity**: Medium
- **Files**: `server/auth/tokens.py` (lines 47-56, 60-75)
- **Description**: Access JWTs include `sub`, `sid`, `token_use`, `iat`, `exp` but no `iss` or `aud`. If the signing key is ever shared across environments (staging vs production), tokens are cross-accepted.
- **Fix**: Add `iss: "tigerduck-backend"` and `aud: "tigerduck-api"` to issue and decode.

**12. In-memory rate limiter does not survive restarts or scale horizontally**
- **Severity**: Medium
- **Files**: `server/auth/rate_limit.py` (entire file)
- **Description**: The `SlidingWindowLimiter` is per-process. Restarting resets counters. The `_attempts` dict grows unboundedly (no periodic sweep or max-key cap).
- **Fix**: Add LRU eviction or periodic sweep for the `_attempts` dict. For production, move to Redis-backed counters.

**13. Retention purge commits all users in one transaction**
- **Severity**: Medium
- **Files**: `server/sync/retention.py` (lines 38-72)
- **Description**: `purge_expired_changelog` holds `FOR UPDATE` locks on every affected `user_sync_state` row simultaneously, blocking concurrent sync writes for all those users until the purge commits.
- **Fix**: Commit per-user or per-batch inside the loop.

**14. Full sync inconsistently filters soft-deleted entities**
- **Severity**: Medium
- **Files**: `server/routes/sync.py` (lines 118-149)
- **Description**: `_read_full_snapshot` filters `deleted_at IS NULL` for settings and subscriptions but does NOT filter it for courses and assignments. Clients doing full sync receive soft-deleted rows.
- **Fix**: Apply a consistent policy — either filter `deleted_at IS NULL` on all entity types or on none (and document).

**15. Unbounded bulletin subscription fan-out in user dispatch**
- **Severity**: Medium
- **Files**: `server/bulletins/user_dispatch.py` (lines 75-86, 138-147)
- **Description**: `_match_new_bulletins` loads ALL enabled subscriptions across ALL users into memory. `_push_pending_matches` loads all unpushed matches with no LIMIT.
- **Fix**: Pre-filter subscriptions by `canonical_org` at the DB level. Add a `.limit(batch_size)` to the unpushed matches query.

**16. Debug endpoints accessible in non-production environments with no auth**
- **Severity**: Medium
- **Files**: `server/routes/debug.py` (lines 36-46)
- **Description**: Debug endpoints are gated by `_require_dev(request)` plus `require_shared_secret` (no-op when unconfigured). Any staging/preview environment exposes debug endpoints with zero authentication.
- **Fix**: Do not mount the debug router at all unless `env == "development"`, or require the shared secret regardless of environment.

### Low

**17. Rate limiter TOCTOU between `allow()` and `record()`**
- **Severity**: Low
- **Files**: `server/auth/rate_limit.py` (lines 46-51)
- **Description**: Between `allow()` returning True and `record()` appending the timestamp, another concurrent async task can also pass `allow()` for the same key.
- **Fix**: Combine `allow` and `record` into a single atomic `try_acquire(key) -> bool` method.

**18. Refresh token grace-retry can silently log out the legitimate client**
- **Severity**: Low
- **Files**: `server/auth/service.py` (lines 275-314)
- **Description**: The grace path revokes the successor and re-rotates from the old session. If the successor had already been used to issue an access token (race), the legitimate client's access token points to the now-revoked successor. The one-shot guard and 60s window make exploitation unlikely.
- **Fix**: Before granting grace retry, check `successor.last_used_at == successor.issued_at`.

### Positive observations

- JWT signing key and refresh HMAC key are independent
- AES-256-GCM credential encryption with per-row AAD binding and random nonces
- v3 push pipeline uses advisory locks + `FOR UPDATE SKIP LOCKED` + idempotent materialization + stale-lock recovery
- No SQL injection — all queries use SQLAlchemy ORM/Core with parameterized values
- `secrets.compare_digest` used for shared-secret checks
- All v3 endpoints auth-gated via `CurrentAuthDep`
- Refresh token family revocation with reuse detection

---

## Android (`~/StudioProjects/tigerduck-app-android`)

346 files changed, 36,703 insertions(+), 16,669 deletions(-)

### High

**1. HIGH — Analytics events buffered locally before user consent**
- **Files**: `app/src/play/java/org/ntust/app/tigerduck/analytics/AnalyticsLogger.kt`, `app/src/main/java/org/ntust/app/tigerduck/ui/navigation/AppNavigation.kt`
- **Description**: `AnalyticsLogger.log()` calls `fa.logEvent()` unconditionally. Firebase's manifest-level `firebase_analytics_collection_enabled=false` prevents upload, but events are still buffered on-device. If a user later opts in, all buffered pre-consent `screen_view` events retroactively upload, exposing navigation history from before consent was granted. GDPR concern.
- **Fix**: Add a guard in `AnalyticsLogger.log()`: `if (!enabled) return` where `enabled` tracks the consent state.

**2. HIGH — Tile timeline entries not sorted/deduped for overlapping course blocks**
- **File**: `wear/src/main/java/org/ntust/app/tigerduck/wear/tile/NextClassTileService.kt`, `addFutureEntries()` (~line 103-128)
- **Description**: The `transitions` list is built by iterating `blocks` and appending start/end minutes sequentially. If two courses have overlapping periods, the transitions list can contain out-of-order or duplicate entries. An unsorted list may produce timeline entries with incorrect validity windows, causing the tile to display the wrong class at boundary times.
- **Fix**: Sort and deduplicate `transitions` before iterating: `transitions.sort(); transitions.distinct()`. Also consider merging overlapping intervals.

**3. HIGH — `BulletinCache.clear()` can deadlock between `mutex` and `detailLocks`**
- **File**: `app/src/main/java/org/ntust/app/tigerduck/data/cache/BulletinCache.kt`, `clear()` (~line 115)
- **Description**: `clear()` acquires `mutex` (for summaries), then iterates detail files calling `withDetailLock(id)` which acquires per-id locks. Meanwhile, `pruneDetails()` acquires per-id locks first without holding `mutex`. Lock ordering is inconsistent: `clear()` takes `mutex` then detail lock, while `loadDetail()/saveDetail()` take only the detail lock.
- **Fix**: Release `mutex` before iterating detail files in `clear()`, or use a single coarse lock for the entire `clear()` operation.

### Medium

**4. MEDIUM — `ServerPushPopupCoordinator.request()` races between disk read and `synchronized` re-check**
- **File**: `app/src/main/java/org/ntust/app/tigerduck/serverpush/ServerPushPopupCoordinator.kt`, `request()` (~line 72-86)
- **Description**: The method reads DataStore (suspending I/O) between two `synchronized(lock)` blocks. Two concurrent `request()` calls for the same `notificationId` that both pass the first check can both reach the DataStore read. Not a functional bug (`activeIds.add()` returning `false` prevents duplicates), but the DataStore read is wasted I/O in the duplicate case.
- **Fix**: Document that the DataStore read is a best-effort optimization, or read it inside the initial synchronized block.

**5. MEDIUM — `FlipDetector` state machine not thread-safe**
- **File**: `app/src/main/java/org/ntust/app/tigerduck/sensor/FlipDetector.kt`
- **Description**: `state`, `registered` are plain `var` fields accessed from the sensor callback and from `register()`/`unregister()`. Currently safe because sensor events default to the main looper. But if ever registered on a background handler, reads would race.
- **Fix**: Add `@MainThread` annotations, or make `state` and `registered` volatile/atomic.

**6. MEDIUM — Onboarding analytics toggle not surviving process death**
- **File**: `app/src/main/java/org/ntust/app/tigerduck/ui/screen/onboarding/OnboardingScreen.kt` (~line 137)
- **Description**: `analyticsEnabled` uses `remember { mutableStateOf(...) }` instead of `rememberSaveable`. On process death, the visual toggle resets to `false` even though the preference was already persisted as `true`, causing a visual desync. The user may re-toggle, triggering an unnecessary `resetAnalyticsData()`.
- **Fix**: Use `rememberSaveable` or derive from `viewModel.prefs.analyticsEnabled`.

**7. MEDIUM — `DataCache.atomicWrite` fallback writes non-atomically after deleting the target**
- **File**: `app/src/main/java/org/ntust/app/tigerduck/data/cache/DataCache.kt`, `atomicWrite()` (~line 400)
- **Description**: When both `renameTo` attempts fail, the code falls back to `target.writeText(content)` directly. But `target.delete()` already ran, so the original data is gone. If the direct `writeText` also fails (disk full), both original and new data are lost. For `manual_courses_*.json` (user data with no remote source), this is silent data loss.
- **Fix**: Only delete `target` after confirming the replacement write succeeded, or keep the original as a backup.

**8. MEDIUM — `TigerDuckDialog` scrollable body can push buttons off-screen on small devices with keyboard**
- **File**: `app/src/main/java/org/ntust/app/tigerduck/ui/component/TigerDuckDialog.kt` (~line 92)
- **Description**: The dialog body has `MAX_HEIGHT_DP = 480` with `.verticalScroll()`, and buttons sit outside the scroll area. With `imePadding()`, the total height can exceed the viewport on small screens (<600dp height), making buttons unreachable.
- **Fix**: Calculate max body height dynamically based on screen height minus keyboard height minus button height.

### Low

**9. LOW — `SecureWindowRegistry` not cleared on Activity leak**
- **File**: `app/src/main/java/org/ntust/app/tigerduck/ui/component/SecureScreen.kt`
- **Description**: Process singleton holding `HashMap<Window, Entry>`. If a composable leaves composition without triggering `onDispose` (crash during composition), the Window entry leaks. Unlikely since Compose guarantees `onDispose`.

**10. LOW — `ServerPushIntentToken` uses `commit = true` on main thread**
- **File**: `app/src/main/java/org/ntust/app/tigerduck/serverpush/ServerPushIntentToken.kt`
- **Description**: Synchronous SharedPreferences write during `@Singleton` init on Application creation. Sub-millisecond for a 16-byte hex write, but contributes to startup latency.

**11. LOW — Plaintext password lingers in heap after onboarding**
- **File**: `app/src/main/java/org/ntust/app/tigerduck/ui/screen/onboarding/OnboardingScreen.kt` (~line 133)
- **Description**: `password` held in `remember { mutableStateOf("") }`. After successful login, the string remains in heap until GC. `SecureScreen` blocks screenshots, but a heap dump could expose the credential.
- **Fix**: Clear `password = ""` after successful login before navigating away.

**12. LOW — `ApiEndpointDebugScreen` sync coroutine cancelled on navigation**
- **File**: `app/src/main/java/org/ntust/app/tigerduck/ui/screen/debug/ApiEndpointDebugScreen.kt`
- **Description**: `scope.launch { pushRegistration.syncNow() }` uses `rememberCoroutineScope()`. Navigating away cancels the scope and silently drops the re-registration. Debug-only screen.
- **Fix**: Wrap in `withContext(NonCancellable)` or move to a ViewModel scope.

**13. LOW — `-dontrepackage` removal needs ongoing verification**
- **File**: `app/proguard-rules.pro`
- **Description**: Removing `-dontrepackage` allows R8 to repackage classes. All current Gson-serialized DTOs are covered by keep rules, but any future DTO added outside these packages without `@SerializedName` annotations will silently break in release builds.
- **Fix**: Add a lint check or CI step that verifies all Gson-deserialized classes are covered by keep rules.

### Positive observations

- Intent spoofing defense via per-install `ServerPushIntentToken`
- `runBlocking` removed from tile and complication services — replaced with proper `serviceScope.launch`
- Tile timeline pre-computing future transitions for battery efficiency
- `CoroutineExceptionHandler` on `ApplicationScope` prevents cascade crashes
- Atomic file writes in `DataCache` and `BulletinCache`
- R8 strict mode + consolidated keep rules
- Assignment scheduler lock + round-robin budget for fair distribution
- `OverrideValidator` allowlist with strict IPv4 parsing and RFC1918 recognition

---

## Apple (`~/tigerduck-app`)

723 files changed, 32,554 insertions(+), 11,476 deletions(-)

### Critical / High

**1. HIGH — `WatchSyncCoordinator` stored as `private let` on `App` struct, not `@State`**
- **File**: `swift/TigerDuck/TigerDuckApp.swift`, line 18
- **Description**: `TigerDuckApp` is a struct. `private let watchSyncCoordinator = WatchSyncCoordinator()` creates a new instance every time SwiftUI re-evaluates the struct. Since `WatchSyncCoordinator` is a `@MainActor final class` that calls `.activate()` in `init()`, multiple WCSession activations can occur, and debounce state / pending payloads are lost on each re-creation.
- **Fix**: Change to `@State private var watchSyncCoordinator = WatchSyncCoordinator()` and move `.activate()` into `.onAppear` with a one-shot guard.

**2. HIGH — `SDAssignment` adds non-optional stored properties without migration support**
- **File**: `swift/TigerDuck/Models/SwiftData/SDAssignment.swift`, lines 13-14
- **Description**: `var isArchived: Bool` and `var isLocallyCompleted: Bool` are non-optional with no `@Attribute` default visible to SwiftData's schema inference. No `VersionedSchema` or `SchemaMigrationPlan` exists. The fallback in `TigerDuckApp.swift` deletes the entire store on migration failure — upgrading users silently lose all persisted courses, assignments, and calendar events.
- **Fix**: Either make these `Optional<Bool>`, mark them `@Transient`, or implement a `VersionedSchema` with a lightweight migration stage.

**3. HIGH — Live Activity 404 re-register can loop without bound**
- **File**: `swift/TigerDuck/Services/Push/PushRegistrationService.swift`, lines ~346-353
- **Description**: When `performActivityRegistration` gets a 404, it calls `registerIfReady()` which on success calls `flushPendingActivityRegistrations`, re-running the same activity registration. If the server keeps returning 404, this creates a tight loop of HTTP request pairs with no circuit breaker. The `activityRegistrationAttempts` counter is only incremented in `scheduleActivityRegistrationRetry`, which the 404 branch bypasses.
- **Fix**: Track 404 re-register attempts per `activityId`. After 1-2 attempts still producing 404, fall through to the exponential-backoff retry path.

**4. HIGH — `AppState` lacks `@MainActor` but owns MainActor-isolated children and mutable state**
- **File**: `swift/TigerDuck/App/AppState.swift`
- **Description**: `AppState` is `@Observable final class` (no isolation) yet owns `@MainActor` children (`liveActivityCoordinator`, `updateNotifyCoordinator`) and has mutable stored properties (`pendingDeepLink`, `pendingServerPopup`, settings vars) freely accessed without isolation. The `relabelTask` property is mutated from `didSet` observers and `Task.detached` closures without synchronization.
- **Fix**: Add `@MainActor` to `AppState`. It is already used exclusively from MainActor contexts.

**5. HIGH — No 401 handling in `PushAPIClient` or `BulletinAPIClient`**
- **Files**: `swift/TigerDuck/Services/Push/PushAPIClient.swift` (lines ~166-177), `swift/TigerDuck/Services/API/Bulletin/BulletinAPIClient.swift` (lines ~140-165)
- **Description**: Both `execute(_:)` methods throw a generic `httpStatus(Int, body:)` for 401. If the shared secret is rotated server-side, the push registration retry loop burns through all 4 attempts against a 401 and gives up, leaving the device permanently un-pushable until the next app restart.
- **Fix**: Add 401-specific detection in `execute()`. Invalidate the cached shared secret, re-resolve via `PushServerConfig.resolveSharedSecret`, retry once with the fresh value.

### Medium

**6. MEDIUM — `MacClassTableView.courses` computed property does heavy disk I/O on every body evaluation**
- **File**: `swift/TigerDuck/Platform/Mac/MacClassTableView.swift`, ~line 96
- **Description**: The `courses` computed property calls 4 separate `DataCache.shared.load*()` methods (each a JSON decode from disk) plus `CanonicalCourseProvider.merge()`. It is referenced 17 times throughout the view body.
- **Fix**: Cache the result in `@State` and update only when `cacheRevision` or `selectedSemester` changes via `.onChange(of:)`.

**7. MEDIUM — `weekdayDisplayName(_:)` allocates a new `DateFormatter` on every call**
- **File**: `swift/TigerDuck/Features/ClassTable/Components/TimetableGridView.swift`, line 7
- **Description**: `DateFormatter` init costs ~20μs. Called once per timetable cell for accessibility labels (~20+ times per body evaluation).
- **Fix**: Hoist to a `private static let` or cache the weekday symbol array at module level.

**8. MEDIUM — `password.hashValue` used for Moodle token dedup key — non-deterministic and collision-prone**
- **File**: `swift/TigerDuck/Services/API/Moodle/MoodleTokenService.swift`
- **Description**: `ObtainKey` uses `String.hashValue` to distinguish concurrent `obtainToken` calls. `hashValue` is randomized per process launch (Swift 4.2+). Two distinct passwords can collide, causing the second caller to receive a token obtained with different credentials, leaking course data across accounts during concurrent account-switch.
- **Fix**: Store the full password string in `ObtainKey`, or use a `SHA256` digest.

**9. MEDIUM — `BulletinsViewModel` background prefetch and manual pagination can interleave cursors**
- **File**: `swift/TigerDuck/Features/Bulletins/BulletinsViewModel.swift`, lines ~176-248
- **Description**: `runBackgroundPrefetch()` and `paginate()` both read/write `nextCursor` and `hasMore` on `@MainActor`. They can interleave at suspension points, causing skipped or re-fetched pages.
- **Fix**: Cancel `prefetchTask` at the start of `paginate()`, and restart it after pagination completes.

**10. MEDIUM — `PushAPIClient.execute` logs error body at `.public` privacy**
- **File**: `swift/TigerDuck/Services/Push/PushAPIClient.swift`, line 173
- **Description**: Error response snippets (which may echo request headers including `X-Push-Token`) are logged at `privacy: .public`, persisting in sysdiagnose bundles.
- **Fix**: Change to `\(snippet, privacy: .private)`.

**11. MEDIUM — `NotificationDelegate.pendingResponses` buffer grows without bound**
- **File**: `swift/TigerDuck/App/NotificationDelegate.swift`, lines 31-63
- **Description**: `pendingResponses` accumulates `UNNotificationResponse` objects until `routeTap` is wired. If `routeTap` is set late, all buffered responses drain simultaneously, potentially opening multiple deep links.
- **Fix**: Cap to 1 (keep most recent response only). Add a staleness check in the `didSet` drain.

**12. MEDIUM — `SDCourse.moodleDeepLink` does synchronous disk I/O from a computed property**
- **File**: `swift/TigerDuck/Models/SwiftData/SDCourse.swift`, lines ~285-337
- **Description**: `moodleDeepLink`, `moodleWebURL`, and `moodleOpenURL` call `DataCache.shared.lookupMoodleCourseId()` which reads and JSON-decodes a file from disk. Called from the Live Activity resolver on MainActor, this blocks UI.
- **Fix**: Cache the Moodle course ID map in a dictionary on `DataCache` at load time.

### Low

**13. LOW — Widget timeline includes entries for skipped courses, wasting reload budget**
- **File**: `swift/TigerDuckWidgets/Logic/WidgetTimelineDerivation.swift`, lines 222-236
- **Description**: `entryDates()` emits timeline refresh entries for every course period, including skipped ones. On an all-skipped day, the widget wakes at each period boundary to re-derive the same `noMoreClasses` state.
- **Fix**: Add `if course.skippedDates.contains(todayKey) { continue }` inside the `entryDates` loop.

**14. LOW — `NextClassWidget` and `TodayWidget` use `.atEnd` policy with empty snapshots**
- **Files**: `swift/TigerDuckWidgets/Widgets/NextClassWidget.swift` (line 43), `swift/TigerDuckWidgets/Widgets/TodayWidget.swift` (line 45)
- **Description**: When snapshot has no courses, `.atEnd` causes an infinite churn loop consuming reload budget. `WeekWidget` correctly uses `.after(midnight)`.
- **Fix**: Use `.after(midnight)` when `snap.courses.isEmpty` or `!snap.isLoggedIn`.

**15. LOW — `WeekWidget` uses `addingTimeInterval(86_400)` instead of calendar arithmetic**
- **File**: `swift/TigerDuckWidgets/Widgets/WeekWidget.swift`, line 38
- **Description**: Hardcoded 86400 seconds for "tomorrow" is fragile across DST transitions. Asia/Taipei doesn't currently observe DST, but the pattern is copy-paste-hazardous.
- **Fix**: Replace with `calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: AppClock.now()))!`.

**16. LOW — TLS pin expiration fail-soft has no user-visible warning**
- **File**: `swift/Shared/TLSPinningDelegate.swift`
- **Description**: After 2027-01-18, TLS pinning silently reverts to system trust. The only signal is a `.fault` log.
- **Fix**: Add a user-visible banner or in-app alert when the pin set is expired or within N days of expiry.

**17. LOW — `LiveActivityCoordinator.deinit` accesses `@MainActor` state from nonisolated context**
- **File**: `swift/TigerDuck/LiveActivity/Runtime/LiveActivityCoordinator.swift`, lines 40-48
- **Description**: `deinit` is nonisolated even on `@MainActor` classes. Accessing `activityObserverTask` and task dictionaries from `deinit` is a Swift 6 strict concurrency violation.
- **Fix**: Remove `deinit` (coordinator is app-lifetime), or use a dedicated `shutdown()` method.

**18. LOW — `saveAssignments` silently drops `isArchived`/`isLocallyCompleted` state**
- **File**: `swift/TigerDuck/Services/Core/DataCache.swift`, lines 579-615
- **Description**: `CachedAssignment` DTO omits the two new booleans. If future code toggles archive state on the `SDAssignment` and calls `saveAssignments` without also calling `addArchivedAssignmentId`, the action silently vanishes on next load.
- **Fix**: Add a doc comment documenting this invariant, or have it automatically sync the ID files from the in-memory state.

### Positive observations

- Consistent `@MainActor` isolation across view models and coordinators
- Clean SwiftUI architecture with proper `@Observable` usage
- TLS certificate pinning with graceful expiry fallback
- DataCache uses atomic write-temp-rename pattern
- Push registration has exponential backoff retry
- Widget timelines use `AppClock` abstraction for testability
