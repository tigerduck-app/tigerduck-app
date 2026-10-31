# Design

## Context

See proposal.md for why. What this design has to work around:

- The app target and the Watch target default to `@MainActor`
  (`SWIFT_DEFAULT_ACTOR_ISOLATION`). Packages do not.
- The project uses synchronized folders. Moving a file needs no project edit, except where an
  extension target lists it by path in a membership exception set. The macOS build lists the
  app's files by base name in `INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]`.
- The widgets and the Live Activity extension do not compile `swift/Shared/`. They keep copies of
  what they need (`WidgetTaipei`, their own now/next logic).
- Sign-out follows ADR 0026: one path, four ordered steps. School Mail and the library are accounts
  of their own, with their own sign-outs.
- A launch before the first unlock after a restart must not read stored data (ADR 0024, #680).
- `tools/check_account_state.py` guards the sign-out inventory, but no workflow runs it.
- Builds and tests run on the xs-mac build host. CI runs only on pull requests to `main` and `dev`
  and on pushes to them.

## Goals / Non-Goals

**Goals:**
- Every type sized to one responsibility, and every shared rule in one home that AGENTS.md names.
- One account scope per account, and sign-out as one ordered plan.
- Data changes flow from observable stores.
- What is sent, and whether it was already sent, decided in one place each, against a v4 backend
  API built for it.
- No generated localization files in git.

**Non-Goals:**
- No new user-facing behaviour, apart from the v4 wire changes listed in D9.
- No change to stored formats (see proposal.md).
- No Android work here. No modules beyond TigerDuckCore yet: a networking or UI package can come
  later, once the layers have held.

## Decisions

### D1. One branch, one pull request, released as 4.0.0
The whole refactor lands on `refactor/v4` as one pull request. CI runs only when it opens. Each
phase ends in signed checkpoint commits, and the phone suite, the watch suite and the mac build
run on xs-mac before the next phase starts.
- Lost: 35 to 40 phased pull requests. Each would have run CI, but intermediate layouts would
  have shipped to `dev` and every phase would have needed compatibility shims.
- Lost: a ratchet baseline for the checks. With one branch, a phase can turn its rules on as it
  finishes.

### D2. Folders by responsibility
`App`, `Account`, `Stores`, `Persistence`, `School`, `Backend`, `Mail`, `Devices`, `Features`, `UI`,
`Platform/Mac`, `Migrations`, `Debug` and `Support` replace `Services/`. `Services/` held school
clients, backend clients, mail and caches together. Files move in one commit of renames only.
- Lost: keeping `Services/` and splitting inside it. That keeps the layer boundaries invisible.

### D3. TigerDuckCore is a local Swift package
The package holds what has no UI and no I/O and is needed by more than one target:
- `TaipeiTime`
- `AcademicTerm`
- `ClassTimeline`, with its own input value type (one meeting: weekday, periods or times, room,
  course key) and a value for the school's changes
- `QuietDayCalendar`

Each target converts its own course data into the input type: `SDCourse` in the app,
`WatchCourse` on the Watch, snapshot items in the widgets. `CourseTimeSlot` stays in the app and,
in phase 3, holds a course key instead of an `SDCourse`.
- Lost: widening `swift/Shared/` and the membership exception sets. That is the mechanism that
  produced the copies, because the extensions do not compile `Shared/`.
- Lost: one package per layer now. That is more churn than one release should carry.
- Name: `TigerDuckCore` follows the Swift convention for the module everything depends on.
  `Domain` is architecture jargon, and `Lib` is not used in Swift.

### D4. Shared homes, listed in AGENTS.md and enforced by a script
`swift/TigerDuck/AGENTS.md` lists each home in one line. Area-only homes go in the folder's own
AGENTS.md.

`tools/check_architecture.py` carries rules that each turn on at a phase (`ENFORCED_PHASE`). It
checks:
- `"Asia/Taipei"` outside TigerDuckCore
- generation checks outside `Account/`
- `dataDidUpdate`
- `UserDefaults` outside `Persistence/`
- `URLSession(` outside the three network homes
- `Task.sleep` outside the clock and concurrency homes
- `Features/` naming lower-layer types
- duplicate base names
- `on_screen_tests` names
- the size budget

Every rule is on by the last commit.
- Lost: prose rules alone. ADR 0026 shows prose plus a script nobody ran.

### D5. Size budget
- A type stays under 250 lines, including extensions in other files and excluding nested types.
- A view stays under 200.
- A class or actor holds at most 10 stored properties.
- A file stays under 400 lines.
- An extension in another file adds only a conformance.

The size parser strips comments and strings, tracks braces and merges extensions. It is tested
against fixtures.
- Lost: a line limit per file only. `AppState` stayed under any file limit by spreading across 16
  files.
- Lost: SwiftSyntax. It is a heavy dependency for one check, and the tested parser covers the
  repository's shapes.

### D6. One session per account, and a sign-out plan
`AccountSession` exists once each for the school account, the library and School Mail. The school
session covers NTUST, Moodle and the TigerDuck backend.

A session gives scoped tasks that sign-out cancels. Every write of fetched data checks
`isCurrent`. The checks happen at session boundaries, not at about 165 call sites.

`SignOutPlan` runs ADR 0026's four steps in order:
1. Stop the work.
2. Move the generation.
3. Clear the account's stores.
4. Start the network calls with the departing session.

A sign-in waits for step 4.

The stores to clear are a static list of `AccountScoped` types per account. Each type deletes its
files and keys by name, so a store unused in this process is still cleared.
`docs/account-state.md` and a rewritten `tools/check_account_state.py` cover the list, and a
workflow now runs the check. `AccountSwitchTests` grows to fill and check every store.
- Lost: one session for all accounts. That breaks ADR 0026: a school sign-out would clear School
  Mail and the library.
- Lost: registering stores as they are built. A store never built in this process would keep its
  files.

### D7. Construction waits for the first unlock
`AppEnvironment` is the composition root. It and every store and session are built inside the
closure `AfterFirstUnlock` runs once protected data can be read. Background entry points ask
`FirstUnlock` first, as today.
- Lost: eager construction in `App.init`. That repeats #680, where an empty read looked like a
  fresh install and wiped credentials.

### D8. Observable stores own app data, and edits are commands
`CourseStore`, `AssignmentStore` and `CourseColorStore` are `@Observable` and persist through the
split persistence stores. File names and formats do not change.

Edits enter as command values. Sync enqueueing and `DeviceSurfaceSyncer` (widgets, Watch, Live
Activity: one debounce, one fingerprint) observe the stores. `EditToken` tells a fetch whether an
edit happened while it ran.
- Lost: keeping `NotificationCenter` with flags. That fan-out is where the "remember to post,
  remember the flag" fixes came from.
- Lost: Combine. `@Observable` is what the views already use.

### D9. Backend v4 and one place for each sync decision
On the client:
- `BackendClient` builds every `/v4` request, adds auth and maps errors.
- `BackendClient` owns the single 401 refresh, with `RefreshTokenUseBudget` keeping today's
  limit of two sends per refresh token, after which the app signs in again.
- `SyncPolicy` decides which categories this device sends and applies.
- `SendLedger` records the last send per channel, using stable hashes.
- `FullSyncRunner` orders one `CategoryReconciler` per category.

`/v4` in `tigerduck-backend` is built for this shape:
- course colours only through the override endpoint
- stable ids for bulletin subscription rules
- schedule sync skipped when nothing changed
- one error envelope

`/v3` and its push payloads stay unchanged for released apps for at least a month after v4
ships. The v4 contract is written down and sent to the Android side before the backend work
starts, and the owner's decisions lead.

Lost:
- Rebuilding the client on `/v3`. Its double colour path and per-call quirks would be locked in.
- Changing `/v3` in place. That breaks every released app.

### D10. Localizations generated at build time
A Run Script phase in each of the five targets runs `app-translation`'s generator
(`--platform apple --output-dir` under `DERIVED_FILE_DIR`) and copies the `.lproj` folders into the
bundle's resources. Nothing is written into the source tree. The phase fails without `python3`,
without the generator, or with fewer than 60 locales.

The 335 symlinks and `app-translation/generated/apple/` go away, and `check_keys.py` reads
`source/en.json`. Xcode Cloud's `ci_post_clone.sh` still initialises the submodules.

Lost:
- Generating into the source tree, with the output gitignored. Synchronized folders read the tree
  when the build plans, and a scheme pre-action that fails does not fail the build.
- Keeping the symlinks. They are generated files under version control, and a missing submodule
  only shows as raw keys at run time.

### D11. Comments
A comment that explains our own ordering, a flag or a guard means the design lacks a type or a
state. The phase that adds that type removes the comment. Comments about the school's servers and
Apple's behaviour stay, on the type that handles them.

### D12. The macOS lists are derived
`tools/check_macos_sources.py --write` regenerates both macOS arrays from the app's files minus
`tools/macos-excluded-sources.txt`. CI checks they match. Base names must be unique in the app
target, which the Xcode build needs anyway.
- Lost: editing the arrays by hand for each of the hundreds of files the splits create.

### D13. A refresh pulls before it uploads
Today each foreground step starts its own task, and a course upload goes out as soon as a school
fetch returns, whether or not this launch has read the backend. On launch, on return to the
foreground and after a sign-in, `SceneActivation` runs one ordered refresh:
1. Pull: ask the revision and, when this device is behind, apply the change feed or a full sync.
   Values merge per field by `hlc`, so an edit this device has not sent yet is kept.
2. Fetch school data. The fetch starts together with step 1; its result is applied after step 1.
3. Push: the outbox, then what step 2 changed, measured against the merged state by `SendLedger`.

Course membership follows the newest school roster, whichever device fetched it. The user's own
edits follow the last writer by `hlc`. A local edit is sent at once and never waits for a pull.
When the pull fails, school data still shows and its uploads wait for the next successful pull, so
a device sends nothing derived from school data before its first pull after a sign-in.
That hold lives in `SyncTarget`, not in its callers, so an upload started outside
`SceneActivation` waits too.
- Lost: finishing the pull before starting the school fetch. It adds the backend round trip to
  every launch for the same result.
- Lost: the backend copy replacing local state. That drops edits made offline.
- Lost: today's unordered tasks. An upload computed before the pull leaves the backend's merge
  rules to undo a stale state.

### D14. Races found on `dev`, and the home that removes each
An audit of `dev` 6880ae2d traced these ordering races. Each one gets a test in the phase that
builds its home. They share five causes, which the specs turn into rules: an edit sent without its
own time, a document written section by section, an edit dropped after failures, two sends of one
channel in flight, and a write computed from a snapshot taken before an `await`.

| # | Race | Severity | Home | Phase |
|---|---|---|---|---|
| R1 | Course colour and name, assignment mark, ignore and holiday writes go without `hlc`, so a late send beats a newer edit from another device | High | outbox sends each op's stamp; `/v4` requires `hlc`; a reply that keeps a newer value is applied by the store that owns the field, which checks the sync switches, a newer queued edit and colour uniqueness | 4 |
| R2 | A notification-settings push writes whole sections from local values, so a pending push or a re-enabled switch reverts another device's change | High | the settings document merges per field against the last synced base | 4 |
| R3 | A course name edit that gets 404 five times is dropped | High | the outbox parks it and retries after the next course upload | 4 |
| R4 | Two bulletin subscription saves in flight: the first reply wipes the second edit from the screen, and a failed second save loses it | High | one save in flight per channel; the newest local state survives every reply | 4, 6 |
| R5 | The user-added course refresh writes its start-of-fetch list after its lookups, losing an add or reviving a delete | High | `CourseStore` applies fetched details to its current state | 3 |
| R6 | The missing-classroom refresh writes its start-of-fetch course list over a newer roster | Minor | `CourseStore`, as R5 | 3 |
| R7 | A course fetch saves names in the language and labels chosen when it started | Minor | a fetch whose display inputs changed is dropped | 3 |
| R8 | Any class table edit drops courses another device added from the user-added file | Minor | `CourseStore` owns membership | 3 |
| R9 | Recent course deletions outlive sign-out and hide the next account's course | Minor | the school `AccountSession` owns them | 2 |
| R10 | A newer schedule list sent while the older one is still on the server can lose to it | Minor | one send in flight per channel, never cancelled | 4 |
| R11 | Keeping the server's side of an assignment conflict applies the snapshot from when the alert opened | Minor | the reconciler re-reads before it applies | 4 |
| R12 | A mail check in flight posts notifications after the user turned them off | Minor | the switch is read right before posting | 7 |
| R13 | A mail list refresh restores a read flag or a removed row changed during the fetch | Minor | `EditToken` in the mailbox | 7 |
| R14 | A Moodle feed refresh restores an unread badge cleared during the fetch | Minor | `EditToken` in the Moodle course store | 6 |
| R15 | A cancelled bulletin prefetch sets the cursor after a refresh | Minor | a cancelled request's result is dropped | 6 |
| R16 | An old mail session's sign-in failure marks the next account as failed | Minor | the mail `AccountSession` | 2 |

- Lost: fixing them on `dev` first. Each fix would be written twice, once in code this refactor
  replaces, and none loses data across accounts.

## Risks / Trade-offs

- [No CI until the end] → Each phase runs the phone suite, the watch suite, the mac build and the
  TigerDuckCore tests on xs-mac, and the light checks locally. Pushing the branch without a pull
  request runs no workflow and serves as a backup.
- [`dev` moves meanwhile] → New features are paused. Fixes that land on `dev` are merged into the
  branch at each phase boundary, while they are small.
- [Sign-out regressions are privacy bugs] → Phase 2 rewrites the account-state check, adds it to
  CI and extends `AccountSwitchTests` before any store moves.
- [Stored formats] → Each store split keeps file names, keys and encodings. Round-trip tests read
  today's fixtures.
- [Order of full-sync categories] → `FullSyncRunner` fixes the order: marks, then course ignores,
  then the roster, then the reset stamp and revision. A test pins it.
- [Refresh token reuse] → `BackendClient` refreshes at most as often as today, and a test counts
  the refresh attempts.
- [First v4 sync uploads everything once] → Accepted: the endpoints are new and `SendLedger` starts
  empty.
- [Review of a very large diff] → Every phase gets a read-only review before the next starts, and
  phases touching sign-out, sync or migrations get a second one after fixes.

## Migration Plan

1. Merge the `app-translation` pull request that stops tracking `generated/apple/`, then bump the
   submodule on the branch.
2. Deploy `tigerduck-backend` with `/v4` alongside `/v3` and check `/v3` traffic is unchanged.
3. Merge `refactor/v4` to `dev`, then release 4.0.0 through the usual release pull request.
4. Retire `/v3` no earlier than a month after 4.0.0, once Android is on `/v4` and the minimum
   supported version (#920) can steer the rest.

Rollback before step 3 is deleting the branch. After step 3, 3.x builds keep working against
`/v3`.
