# App target

Rules for `swift/TigerDuck/`, the iOS app and its native macOS build. Read `School/AGENTS.md`,
`Backend/AGENTS.md`, `Mail/AGENTS.md`, `Migrations/AGENTS.md` and `Devices/LiveActivity/AGENTS.md`
before working in those directories. docs/decisions/0028-v4-layout.md explains the folders,
the shared homes and the size budget.

## Conventions

- Add no new responsibilities to `AppState`; feature state lives in the feature's view model or
  service. Features read auth and protected-access state from `AppState` instead of keeping
  their own copy.
- `Account/AuthService.swift` coordinates auth. It tells cookie-valid auth apart from stored
  credentials, and keeps credentials through silent re-auth failures.
- Feature view models are `@Observable` and show cached data first. App launch, an explicit
  refresh, or a return to the app once the school data is a minute old
  (`AppServiceBridge.refreshAssignmentsIfDue`) does the network fetch.
- Moodle assignments come from `AppServiceBridge.fetchAssignments`. It runs one round at a time
  for every caller, rebuilds the calendar's Moodle rows and stamps `schoolDataSyncedAt`, which
  the sync status popup shows. Only a pull, or Refresh on the Mac, passes
  `recheckSubmissions: true`. A status the assignment page fetches goes in through
  `AppServiceBridge.takeSubmissionStatus`, which waits out a running round, keeps the newest
  answer and leaves `schoolDataSyncedAt` alone; any other write to the cached assignments goes
  through one of these two.
- Cross-feature updates go through the `NotificationCenter` names in `AppConstants`
  (`dataDidUpdate`, `liveActivityPreferencesDidChange`, `languageDidChange`, ...). There is no
  dependency-injection container or store framework.
- Styling goes through `TigerDuckTheme`, `VisualPreset` and `VisualStylePolicy`.
- Day and class-time math uses the Taipei calendar (`TaipeiTime` in TigerDuckCore), never
  `Calendar.current`. Schedule-sensitive code reads the time through `Support/Clock/AppClock`, so
  the debug clock override applies.
- Persistence is split: SwiftData models in `Persistence/Models/` and JSON caches in
  `Persistence/DataCache.swift`. Fetched results are written through `DataCache`, so features and
  background sync read the same persisted data.
- Logging goes through `AppLogger`, whose `os.Logger`s write to the system log on the device and
  nowhere else. `captureError` and `breadcrumb` log their text as private, which a logging
  profile can reveal, so they still scrub tokens, passwords and URL query strings first; do not
  use `print`.
- Console and a sysdiagnose show `.public` values without a logging profile. Log errors and
  their descriptions as `.private`, since they can hold a response body or a server message,
  and course data and backend ids too: course numbers and keys, device, Live Activity and token
  ids, and request paths that hold one. Fixed labels, counts, booleans and status codes stay
  `.public`. `tools/check_comments.py` reports an error logged as `.public`.
- A rule with no screen and no I/O that the Watch app or an extension also needs goes in
  `swift/Packages/TigerDuckCore/`, which the app, the Watch app and all three extensions link.
  Other code the Watch app also needs goes in `swift/Shared/`, which both targets compile; the
  `TigerDuckWidgets` and Live Activity extensions do not compile it.

## Shared homes

Each rule below has one home. Call it instead of writing the rule again;
`tools/check_architecture.py` fails a second copy once the rule's phase is enforced. A home not
yet in the tree arrives with its refactor phase; until then the rule stays where it is.

- Signed-in account, sign-out, writes after a sign-out: `Account/AccountSession.swift`.
  A store of one account's data conforms to `AccountScoped`.
- Courses and assignments, and every edit to them: `Stores/CourseStore.swift`,
  `Stores/AssignmentStore.swift`.
- Course colors: `Stores/CourseColorStore.swift`.
- Term codes: `AcademicTerm` in TigerDuckCore.
- Today's classes, now and next: `ClassTimeline` in TigerDuckCore.
- Days without classes, from the terms and holidays: `QuietDayCalendar` in TigerDuckCore.
- Taipei dates: `TaipeiTime` in TigerDuckCore.
- What this device may send or apply: `Backend/Sync/SyncPolicy.swift`.
- Whether an upload already went out: `Backend/Sync/SendLedger.swift`.
- Requests to the TigerDuck backend: `Backend/Client/BackendClient.swift`.
- A full sync's categories: one `CategoryReconciler` each, in `Backend/Sync/Reconcilers/`.
- Freshness of a cached answer: `Persistence/FreshnessPolicy.swift`.
- A school service bouncing to the portal: `School/NTUST/SchoolSessionRecovery.swift`.
- Waiting for a state: `StateSignal`; for a time: `AppClock.sleep(until:)` in `Support/Clock/`.
- Deep links and sheets: `App/Routing/AppRouter.swift`.
- Widget, Watch and Live Activity refresh: `Devices/DeviceSurfaceSyncer.swift`.

## Size

A type stays under 250 lines, extensions in other files included, and a view under 200; a class
or actor holds at most 10 stored properties, and a file stays under 400 lines. Split by
responsibility; nested types are fine. `tools/check_architecture.py --report` lists what is over.

## Anti-patterns

- Do not gate protected NTUST screens on cookie validity or on `isNTUSTLoggedIn` alone; silent
  re-auth is expected. Use `ntustProtectedAccessState(isEmpty:)`.
- Do not write the previous user's data back after logout. Bridge and service code check their
  account's `AccountSession` (`isCurrent`, or a scoped task) and cancellation before writing.
- Do not call `AuthService.login` to re-authenticate silently: it harvests a new Moodle token
  and drops the course cache. The Moodle token renews itself on `.invalidToken`.
- Do not store secrets in `UserDefaults`; credentials live in the Keychain.
- Do not contact the TigerDuck backend from launch code before onboarding completes; a fresh
  install runs `AppState.init` before the user has seen a screen. Check `hasCompletedOnboarding`
  as `AppState.init` does before `pushCoordinator.enable()` and as `backgroundSync()` does;
  `completeOnboarding()` starts both.
- Do not read `UserDefaults`, the Keychain or the app's files in `TigerDuckApp.init` outside
  the closure `TigerDuckApp.makeLaunch` hands `AfterFirstUnlock`: a background launch before the
  first unlock after a restart reads them as empty, and that closure runs only once they can be
  read (docs/decisions/0024-launch-before-first-unlock.md). A background entry point that can run
  before that closure, as School Mail's background refresh does, asks
  `FirstUnlock.storedDataReadsBack()` before it reads stored data.
- Do not trigger a Live Activity refresh for presentation-only changes such as `visualPreset`.
- Do not add one-off spacing or color systems next to the shared theme.
- Do not put a plain `.onTapGesture` on content in a ScrollView or lazy grid, or a plain tap or
  long-press over all of it; since iOS 18 the former fires only on a second tap and the latter
  eats each child's first tap. Use the helpers in `UI/ViewHelpers/View+ScrollSafeGesture.swift`.
- Do not edit the macOS source arrays in `project.pbxproj` by hand or give two Swift files one
  base name (see the root AGENTS.md).

## Tests

- Unit tests are in `swift/TigerDuckTests/` (Swift Testing and XCTest) and run in CI on every
  pull request to `main` and `dev`. UI tests in `swift/TigerDuckUITests/` do not run in CI.
- The unit tests' host app shows an empty scene (`TigerDuckLauncher` in
  `App/TigerDuckApp.swift`), so nothing from `TigerDuckApp` runs: a test installs the hooks it
  needs itself, as `LiveMailClientTests` does with `SchoolMailCharsetHook.install()`.

## Gotchas

- Sign-out is a privacy boundary: `SignOutPlan` clears every `AccountScoped` store of the
  account, `DataCache.clearUserScopedData()` among them, before another login can use the app.
- `NetworkMonitor` is observable state; some refresh paths read it before fetching.
- macOS sidebar pins are stored in `macConfiguredTabs`, apart from the iOS tab configuration.
