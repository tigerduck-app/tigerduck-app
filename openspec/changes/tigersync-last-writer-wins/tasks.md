# Tasks

Groups are pull requests in merge order: backend, then iOS, then Android. Backend work happens
in `tigerduck-app/tigerduck-backend` on branches from `origin/dev`; backend tests run with
`uv run pytest server/tests/` against a throwaway Postgres (`TIGERDUCK_TEST_DATABASE_URL`). iOS
tests run with the `TigerDuckTests` command in the root AGENTS.md. Android work happens in
`tigerduck-app/tigerduck-app-android` and is its maintainer's.

## 1. Backend PR: clock and per-field merge

- [x] 1.1 In `server/sync/merge.py`, add the microsecond conversion, clamp at backend time plus five seconds (replacing `clamp_ts`), and make `apply_field` keep ties, raise the stamp on equal content without reporting a change, and take any stamp when none is stored; verify new cases in `server/tests/test_sync_merge.py` pass
- [x] 1.2 Add the `X-TigerSync-Clock` middleware for every `/v3` response in `server/main.py` and a dependency that reads `X-TigerSync-Protocol: 2`; verify a test sees the header on a 200, a 404 and a 422
- [x] 1.3 Make both PATCH routes in `server/routes/overrides.py` take `lock_sync_state` before reading, accept `hlc` (arrival time when absent, 422 when absent under protocol 2), compare colour, each locale's name and the ignore setting by stamp, keep a cleared mark as a stamped `none` on every row of the assignment, return the winners with `applied`, and log a change and queue `sync_trigger` only when a value changed; verify new cases in `server/tests/test_sync_overrides.py` pass, including a refused edit that leaves the revision unchanged
- [x] 1.4 Take the stamp in `PUT /v3/sync/holiday-overrides/{id}` (`server/routes/holiday_overrides.py`), stored in `updated_at`, under the same lock and rules; verify `server/tests/test_holiday_overrides.py` covers older, newer and same-content edits
- [x] 1.5 Route `server/routes/academics.py`'s PUTs and `server/sync/upload.py` through the locked merge, counting a value without a time as oldest; verify `server/tests/test_sync_initial_upload.py` passes with that expectation
- [x] 1.6 Write the Alembic revision for `custom_names_updated_at` and the missing-stamp backfill (design.md, Migration Plan steps 1 and 2); verify a migration test seeds rows, upgrades, checks the stamps and downgrades
- [x] 1.7 Add `server_hlc` and the `*_hlc` fields to `/v3/sync/full` and the serializers (`server/sync/serializers.py`); verify a snapshot test reads them and that the existing snapshot tests pass unchanged
- [x] 1.8 Add a test that writes one field from two sessions at once with stamps a second apart; verify the later stamp is stored in each of 20 rounds the test runs
- [x] 1.9 Describe the clock and merge rules in `server/AGENTS.md`'s Conventions; verify the pull request's CI passes and review finds the text matches the code
- [x] 1.10 Read `server_hlc` in `server/routes/sync/snapshot.py` before the snapshot's first query; verify a test that a write's `X-TigerSync-Clock` is earlier than the `server_hlc` of a snapshot read after it

## 2. Backend PR: course membership by the clock

- [x] 2.1 Write the Alembic revision for `user_courses.added_at` and `user_semester_resets` with their backfill (Migration Plan steps 3 and 4); verify a migration test upgrades and downgrades seeded rows
- [x] 2.2 Under protocol 2, make `DELETE /v3/sync/courses/{course_key}` take `hlc` and `kind`, compare with `added_at`, the tombstone and the resets, write the tombstone even with no row, and answer the winner; make an add beat `added_at` too, so an older add never moves it back; verify tests for hide and removal, older and newer, and for an add, an older add, then a hide stamped between them
- [x] 2.3 Under protocol 2, make `DELETE /v3/sync/courses` record the term's `reset_at` or `courses_reset_at` from `hlc` only when later than the stored one, clear only rows, tombstones and override fields stamped at or before it (design.md D10), keep writing the per-course reset tombstones for the rows it deletes, and make the override PATCHes and membership writes refuse edits for that term stamped earlier; verify tests for a stale hide, add, colour and name after a reset, a reset arriving after a later add, hide and colour, and an older reset after a newer one
- [x] 2.4 Under protocol 2, add `adds` to `POST /v3/sync/courses/upload` and apply design.md D10's roster rules, keeping a removal tombstone beside the school row; leave the path without the header unchanged; verify tests that a hidden course stays hidden under a fresh roster, that a removed hand-added course shows once the roster lists it and an older hide arriving after that is refused, and that a released app's upload is still bound by a protocol-2 reset
- [x] 2.5 Under protocol 2, return every tombstone with `hlc` and `kind`, `term_resets`, `courses_reset_hlc` and `courses[].added_hlc` from `/v3/sync/full`, keeping the 30-day window without the header and leaving out a removal tombstone whose key has a row; verify snapshot tests for both shapes
- [x] 2.6 Add API-level tests for each case listed in app issue #689 (a delete queued before a re-add elsewhere, a reset then a waiting add, a lost reply and its retry); verify they pass
- [x] 2.7 Rewrite the tombstone conventions in `server/AGENTS.md` for both protocols; verify the pull request's CI passes and review finds the text matches the code

## 3. Backend release

- [ ] 3.1 Release the backend with groups 1 and 2 through its usual dev to main pull request, and have the owner deploy it; verify on the deployed backend that a response carries `X-TigerSync-Clock` and that a released iOS and Android build still sync a colour, a mark and a hide

## 4. iOS PR: the clock and stamped edits

- [ ] 4.1 Add `SyncClock` in `swift/TigerDuck/Services/CloudSync/` with the stamping rule and two `Defaults` keys, assigned to the macOS build as root AGENTS.md requires; verify Swift Testing cases for the rule, two edits in one microsecond, relaunch and a last seen value that never drops, and `python3 tools/check_macos_sources.py`
- [ ] 4.2 Raise the last seen value from `X-TigerSync-Clock` in `PushAPIClient.execute` while protected data is readable; verify a test with a stub `URLProtocol` and one that ignores the header with protected data unavailable
- [ ] 4.3 Stamp every outbox op through `SyncClock` and send its stamp as `hlc` on the override PATCHes and the course DELETE; keep the stored shape so queued entries send their queue time; verify tests on the request bodies and on an entry decoded from today's file format
- [ ] 4.4 Send the edit's stamp on the holiday PUT, including from `retryUnacknowledgedHolidayOverrides`; verify a test that a retried PUT carries the original stamp

## 5. iOS PR: per-field pull and unsent edits

- [ ] 5.1 Apply the snapshot per field by design.md D12 for marks, colours, names and ignore settings, with a map on `CloudSyncCoordinator` from each field to its last acknowledging response's `X-TigerSync-Clock`, and apply a write response's winner only to fields not edited again since; verify tests for a field held while queued, held while the snapshot's `server_hlc` is not later than its acknowledgement, and adopted otherwise, absence after a hide included, and for an edit made while a write is in flight
- [ ] 5.2 Keep outbox entries while TigerSync or their category is off (hold, do not clear in `performDisable` or drop in the `enqueue*` guards), clearing them on sign-out; verify tests for an edit made while off and sent on enable, and for sign-out
- [ ] 5.3 Queue local values stamped 0 at the first sync of a category not in `categoriesSyncedOnce` and nothing for one in it (D13); verify tests for both
- [ ] 5.4 Remove the per-assignment conflict alert (`syncConflicts`, `resolveSyncConflicts`, its alerts in `HomeView` and `MacHomeView`) and the heuristics D12 lists for marks, colours, names and ignore settings; verify the phone and watch test suites and the macOS build pass, and list the removed user-visible strings in the pull request for the owner

## 6. iOS PR: course membership on protocol 2

- [ ] 6.1 Send `X-TigerSync-Protocol: 2` on every backend request; send hides and removals with `kind` (a hand-added course by the rule in `DataCache.deleteCourse`), adds as `adds` with their stamp, and resets with `hlc`; verify request tests for each
- [ ] 6.2 Rebuild `AppState.reconcileCourses` on tombstones, kinds, `term_resets` and `courses_reset_hlc`, with pending outbox ops held, and delete the course heuristics D12 lists; verify tests for each #689 case against a fake backend, then update `docs/decisions/0005-course-tombstones.md` (or supersede it with a new ADR) and verify `python3 tools/check_comments.py check --base origin/dev` passes
- [ ] 6.3 Run the two-device checks of design.md's test plan on real devices against a backend built from `dev`; verify each #689 case ends with both devices agreeing

## 7. iOS PR: refresh order

- [ ] 7.1 Make `backgroundSync` the pipeline of design.md D14 and call it from `HomeView.refreshable`, `MacRootView`'s Refresh and the Calendar, Class Table and Score pulls before their own fetch; with the 3-second wait cap (design.md, Owner decisions, item 2); verify a test where a fake school fetch starts only after the TigerSync step returns, and one where the step fails
- [ ] 7.2 Verify that a revision change and a sync push still run TigerSync alone, with a test that records no school fetch

## 8. iOS PR: the re-enable prompt (after the owner decides D15)

- [ ] 8.1 If the owner agrees, remove `checkPendingConflicts`, `resolveReenableConflict`, `ReenableConflict`, `UseLocalHold`, `ConflictCheckRetry`, `keepLocalCourses`, `queueLocalEdits` and their alerts in `CloudSyncSettingsView`, `SyncContentSettingsView` and `MacTigerSyncSettingsView`, and simplify `signOutDeletesUnsyncedData` without pending checks; verify the phone and watch suites and the macOS build pass, and the owner approves the list of removed strings
- [ ] 8.2 Remove the unused conflict keys in an `app-translation` pull request and bump the submodule; verify `python3 tools/localization/check_keys.py` passes

## 9. iOS release

- [ ] 9.1 Confirm group 6 removed the heuristics the merged `fix/course-outbox-ordering` added, and close #689 and the issues merged into it, each with the test that covers it; verify every item listed in #689 names a passing test from group 2 or 6
- [ ] 9.2 Ship the release with the `release-bump` skill; verify its review of `origin/main...origin/dev` leaves no finding of High severity or above

## 10. Android (its maintainer, after group 3)

- [ ] 10.1 Persist the clock, read `X-TigerSync-Clock`, and send `X-TigerSync-Protocol: 2` and each edit's stamp from `push/PushApiClient.kt` and `push/SyncApiClient.kt`; verify `./gradlew :app:testPlayDebugUnitTest`
- [ ] 10.2 Add a persisted queue of stamped unsent edits, one per field, kept while sync or the category is off; verify unit tests for an offline edit surviving a process restart
- [ ] 10.3 Apply the snapshot per field (design.md D12) in `HomeBackendSync.pull`, rebuild `CourseSyncReconciler` on tombstones, kinds and resets, and remove the per-assignment conflict dialog; verify the reconciler tests cover each #689 case
- [ ] 10.4 Pull before the school fetch in `HomeViewModel` and `BackgroundSyncWorker`; verify a unit test of the order
- [ ] 10.5 Remove the re-enable dialog in `CloudSyncSettingsScreen` if the owner agrees to D15; verify the Android CI passes

## 11. Across clients

- [ ] 11.1 After each app release, run the cross-client checks of design.md's test plan (a released Android with a new iPhone, then both new) for a colour, a mark, a hide and a reset; verify both devices agree in every case

## Workflow follow-up

- Archive the change with `openspec archive tigersync-last-writer-wins` after the last pull request merges.
- Remove the legacy branches in a separate change (design.md, Migration Plan, Rollout step 4).
