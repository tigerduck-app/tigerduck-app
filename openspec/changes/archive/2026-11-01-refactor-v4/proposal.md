# Proposal

## Why

Since 2026-07-01, 1,076 of the 2,207 commits on `dev` were fixes. They cluster in the same files:
`AppState+BackendSync.swift` (63 of 88 commits), `AppState.swift` (50 of 87),
`AppState+Conflicts.swift` (48 of 59), `CloudSyncCoordinator.swift` (46 of 67) and
`AuthTokenManager.swift` (38 of 51). The repeats trace to six design gaps:

- No object represents a signed-in account. About 165 call sites compare login generations, and
  sign-out cleanup lives in four places.
- Whether to send a piece of data, and whether an answer is stale, is decided at each call site.
  Dedupe uses six mechanisms and staleness four.
- Changes spread through `dataDidUpdate` notifications plus flags (40 sites).
- One rule is kept in several copies: now/next class 4 times, the Taipei calendar 3 times, service
  bounce retry 3 times.
- Code waits by sleeping or polling in every area.
- Coordinators are oversized. `AppState` is 3,263 lines across 16 files; 69 types exceed 250 lines.

The features are complete, so this is the time to fix the structure rather than add to it.

## What Changes

- Sources move into folders by responsibility: `App`, `Account`, `Stores`, `Persistence`,
  `School`, `Backend`, `Mail`, `Devices`, `Features`, `UI`, `Support`, `Migrations`, `Debug`.
- A local Swift package, `TigerDuckCore`, holds the rules that have no UI and no I/O: the Taipei
  calendar, term codes, the class timeline and quiet days. The app, the Watch app, the widgets, the
  complication and the Live Activity link it, and their copies go away.
- Every shared rule gets one home, listed in `swift/TigerDuck/AGENTS.md`.
  `tools/check_architecture.py` fails a second copy, a type over its size budget, and code outside
  its layer.
- Each account (school, library, School Mail) gets its own session scope. Sign-out follows one
  ordered plan, and the stores to clear are a static list of types.
- `@Observable` stores own courses, assignments and course colours. Edits enter them as commands,
  and widgets, Watch, Live Activity and sync observe them. The `dataDidUpdate` fan-out goes away.
- **BREAKING**: the app talks to a new backend API, `/v4`, built in `tigerduck-backend` alongside
  `/v3`. One backend client owns requests and the single 401 refresh. One sync policy decides what
  is sent, one send ledger decides whether it was already sent, and each full-sync category gets
  its own reconciler. `/v3` stays for released apps for at least a month after v4 ships.
- `AppState` and `AppServiceBridge` are split into the homes above and removed.
- Feature view models and views are split to the size budget, and the Mac views share the iOS view
  models.
- Localizations are generated at build time from `app-translation/source/` into each bundle. The
  335 tracked `.lproj` symlinks and the checked-in `generated/apple/` go away.
- Comments that explain our own ordering, flags or guards are replaced by code. Comments about the
  school's servers and Apple's behaviour stay, on types whose names carry the meaning.
- The app ships as 4.0.0.

Out of scope:
- New features, including the minimum supported app version (#920), which follows this change.
- Android code. Android moves to `/v4` on its own schedule while `/v3` stays.
- The vendored SwiftMail package.
- Stored formats: Defaults keys, Keychain items and access groups, App Group files, the outbox
  file, the mail cache and index, share codes, SwiftData model fields and the course colour file
  are read as they are today.

## Capabilities

### New Capabilities
- `code-architecture`: where shared rules live, how big a type may get, and how
  `tools/check_architecture.py` enforces both.
- `localization-build`: localizations are generated from `app-translation/source/` at build time
  and are not tracked.

### Modified Capabilities
- `agent-workflow`: the rule against growing `AppState` is replaced by the rule that new work uses
  the shared homes.
- `ci-test-gate`: every pull request also runs the architecture, account-state and TigerDuckCore
  checks.
- `code-comments`: a comment explaining our own ordering or guard is answered with a code change.

## Impact

- Every Swift source of the app target, plus the Watch app, widgets, complication and Live
  Activity; `project.pbxproj`; the tests that reference `AppState` (37 files).
- `tools/`: new `check_architecture.py`; changes to `check_macos_sources.py`,
  `check_account_state.py` and `localization/check_keys.py`.
- `.github/workflows/`, `swift/ci_scripts/ci_post_clone.sh`, `docs/account-state.md`, and a new
  ADR in `docs/decisions/`.
- `app-translation` stops tracking `generated/apple/`.
- `tigerduck-backend` gains `/v4`. Android keeps using `/v3` until it moves.
