# App target

Rules for `swift/TigerDuck/`, the iOS app and its native macOS build. Read `School/AGENTS.md`,
`Backend/AGENTS.md`, `Mail/AGENTS.md`, `Migrations/AGENTS.md` and `Devices/LiveActivity/AGENTS.md`
before working in those directories.

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
- Day and class-time math uses the Taipei calendar (`AppConstants.taipeiCalendar`), never
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
- Code the Watch app also needs goes in `swift/Shared/`, which both targets compile. The
  `TigerDuckWidgets` and Live Activity extensions do not compile it and keep their own copies,
  such as `WidgetTaipei`.

## Anti-patterns

- Do not gate protected NTUST screens on cookie validity or on `isNTUSTLoggedIn` alone; silent
  re-auth is expected. Use `ntustProtectedAccessState(isEmpty:)`.
- Do not write the previous user's data back after logout. Bridge and service code check the
  login generation and cancellation before writing.
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
- Do not add a file without assigning it a platform for the macOS build (see the root
  AGENTS.md).

## Tests

- Unit tests are in `swift/TigerDuckTests/` (Swift Testing and XCTest) and run in CI on every
  pull request to `main` and `dev`. UI tests in `swift/TigerDuckUITests/` do not run in CI.
- The unit tests' host app shows an empty scene (`TigerDuckLauncher` in
  `App/TigerDuckApp.swift`), so nothing from `TigerDuckApp` runs: a test installs the hooks it
  needs itself, as `LiveMailClientTests` does with `SchoolMailCharsetHook.install()`.

## Gotchas

- `DataCache.clearUserScopedData()` is a privacy boundary: logout purges the previous user's
  data before another login can use the app.
- `NetworkMonitor` is observable state; some refresh paths read it before fetching.
- macOS sidebar pins are stored in `macConfiguredTabs`, apart from the iOS tab configuration.
