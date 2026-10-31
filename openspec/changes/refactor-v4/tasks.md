# Tasks

One pull request, `refactor/v4` to `dev`. The groups are its phases, in commit order. The checks
named below run on xs-mac (`remote-xcb`) or locally for the Python checks. A group is done when its
last task's check passes and a read-only review finds nothing High or above.

## 0. Guardrails and layout

- [ ] 0.1 Move the sources into the v4 folders with renames only, and fix every path reference: the pbxproj membership exception sets, AGENTS.md, docs, tools, skills, workflows and comments. Check: a grep for the old prefixes finds nothing outside `openspec/changes/archive/`; the phone and watch suites and the mac build pass.
- [ ] 0.2 `tools/check_macos_sources.py --write` regenerates the macOS lists and rejects duplicate base names. Check: its unit test, and the script passes on the branch.
- [ ] 0.3 Create `swift/Packages/TigerDuckCore` with `TaipeiTime`, link it to the five targets, and remove every other Taipei calendar copy. Check: `swift test` in the package; the phone and watch suites; `"Asia/Taipei"` appears only in TigerDuckCore.
- [ ] 0.4 Add `tools/check_architecture.py` with per-phase rules, its unit tests and `.github/workflows/architecture.yaml`. Check: `python3 -m unittest discover -s tools -p 'test_*.py'`; the script passes at `ENFORCED_PHASE = 0`.
- [ ] 0.5 Generate localizations at build time in the five targets, remove the 335 symlinks, point `check_keys.py` at `source/en.json`, update `ci_post_clone.sh`, and stop tracking `generated/apple/` in `app-translation`. Check: on xs-mac the app and every extension bundle hold 67 `.lproj` folders, and a build without the submodule fails.
- [ ] 0.6 Add the shared homes, the size budget and the comment rule to AGENTS.md, and the v4 layout ADR. Check: `python3 tools/check_comments.py check --base origin/dev`.

## 1. TigerDuckCore rules

- [ ] 1.1 Add `AcademicTerm` (parse, order, previous and next, summer) and replace every term-code rule in the app. Check: package tests built from today's behaviour, including `114H` and padded years; `SemesterCatalogTests` and the course reconcile tests pass.
- [ ] 1.2 Add `ClassTimeline` and its input value types, with converters from `SDCourse`, `WatchCourse` and the widget snapshot items. Replace the four now/next copies. Check: package tests for days, boundaries, skipped and changed slots; the phone and watch suites; widget timeline tests.
- [ ] 1.3 Add `QuietDayCalendar` and use it in the widgets and the Watch. Check: package tests; the watch suite.
- [ ] 1.4 Turn on phase-1 rules. Check: `check_architecture.py` passes at `ENFORCED_PHASE = 1`.

## 2. Account scopes and sign-out

- [ ] 2.1 Rewrite `tools/check_account_state.py` for the new layout and add it to the architecture workflow. Check: its unit test; it fails on a cache file declared without a row.
- [ ] 2.2 Add an `AccountSession` for the school account, the library and School Mail, and route every login-generation check through them. Check: no generation comparison outside `Account/`; `AccountSwitchTests` and the logout race tests pass.
- [ ] 2.3 Add `SignOutPlan` with ADR 0026's four steps and the static list of `AccountScoped` types. Move the school sign-out out of `AppState`. Check: `AccountSwitchTests` fills and checks every store, including ones not loaded in the process; a sign-in waits for step 4.
- [ ] 2.4 Add `StoredPasswordBackoff` for NTUST and the library. Its Defaults keys do not change. Check: the backoff tests of both.
- [ ] 2.5 Turn on phase-2 rules. Check: `check_architecture.py` passes at `ENFORCED_PHASE = 2`; the phone suite; review twice (sign-out is a privacy boundary).

## 3. Persistence and stores

- [ ] 3.1 Split `DataCache` into per-domain persistence stores with the same file names and formats, each `AccountScoped`. Check: round-trip tests read today's files; `AccountSwitchTests`.
- [ ] 3.2 Add `FreshnessPolicy` and `CachedValue`, and move the seven TTLs onto them. Check: the cache tests of each service.
- [ ] 3.3 Add `CourseStore`, `AssignmentStore`, `CourseColorStore` and `EditToken`. Edits become commands. `CourseTimeSlot` holds a course key. Check: store tests; the class table, home and course detail tests.
- [ ] 3.4 Add `DeviceSurfaceSyncer` and move the widget, Watch and Live Activity refreshes onto store observation. Remove `dataDidUpdate` and `isUpdatingFromNetwork`. Check: no `dataDidUpdate` left; the Live Activity and widget tests; the watch suite.
- [ ] 3.5 Turn on phase-3 rules. Check: `check_architecture.py` passes at `ENFORCED_PHASE = 3`; the phone suite.

## 4. Backend v4 and sync

- [ ] 4.1 Write the `/v4` contract (endpoints, payloads, error envelope; colours through overrides only; stable bulletin rule ids; schedule sync skipped when unchanged) in `tigerduck-backend` and send it to the Android side. Check: the owner accepts the contract.
- [ ] 4.2 Build `/v4` in `tigerduck-backend` beside `/v3`, with `/v3` and its push payloads unchanged. Check: backend tests through `remote-pytest`; the `/v3` tests unchanged and passing.
- [ ] 4.3 Add `BackendClient`, `SyncTarget` and `RefreshTokenUseBudget`, and split `AuthTokenManager`. Check: the auth tests; a test counts refresh attempts and matches today.
- [ ] 4.4 Add `SyncPolicy` and `SendLedger`, and move every upload channel onto them. Check: tests per channel, including schedule sync skipping an unchanged list and stable fingerprints across launches.
- [ ] 4.5 Split `runFullSync` into `FullSyncRunner` and one `CategoryReconciler` per category. Split `CloudSyncCoordinator` and the outbox. Check: a test pins the category order; the sync and conflict tests; the outbox file round-trips.
- [ ] 4.6 Point the app at `/v4`. Check: the phone suite against fixtures of the v4 contract.
- [ ] 4.7 Turn on phase-4 rules. Check: `check_architecture.py` passes at `ENFORCED_PHASE = 4`; review twice.

## 5. App shell

- [ ] 5.1 Add `AppEnvironment`, built only inside the `AfterFirstUnlock` closure, and `AppPreferences`. Check: the launch-before-first-unlock tests; the phone suite.
- [ ] 5.2 Add `AppRouter` and `SceneActivation`, replacing window walking and deep-link polling. Check: the deep link and sheet tests; the mac build.
- [ ] 5.3 Split `AppServiceBridge` into `School/Courses/` and `School/Moodle/`. Remove `AppState` and move its 37 test references. Check: no `AppState` left; the phone suite.
- [ ] 5.4 Turn on phase-5 rules. Check: `check_architecture.py` passes at `ENFORCED_PHASE = 5`.

## 6. Features

- [ ] 6.1 Split the class table, home and calendar view models and views, and give the Mac views the shared view models and `ClassTableEditor`. Check: their tests; the mac build.
- [ ] 6.2 Split the Moodle course store and views, the library view model (a state enum instead of flags and timers), bulletins, empty classrooms, score, settings, onboarding, browser and updates. Check: their tests.
- [ ] 6.3 Turn on the size budget and layer rules. Check: `check_architecture.py` passes at `ENFORCED_PHASE = 6`; the phone and watch suites; the mac build.

## 7. School Mail and waiting

- [ ] 7.1 Add `MailSettingsStore`, `MailInboxCursor`, `MailboxEvents` and `MailErrorClass`, and split `LiveMailClient` and the mail view models. Check: the mail tests; the cache and index formats round-trip.
- [ ] 7.2 Replace every remaining sleep-wait with `StateSignal` or `AppClock.sleep(until:)`. Check: no `Task.sleep` outside the clock and concurrency homes.
- [ ] 7.3 Turn on every rule. Check: `check_architecture.py` passes with all rules on; every light check; the phone and watch suites; the mac build; the TigerDuckCore tests.

## 8. Pull request

- [ ] 8.1 Merge `dev` into the branch and resolve. Check: every check above again.
- [ ] 8.2 Open the pull request, with the owner's go-ahead to push. Check: GitHub CI green, and the bots' findings addressed.

## Workflow follow-up

- Deploy `/v4`, release 4.0.0, and retire `/v3` no earlier than a month later.
- Archive this change after the pull request merges.
