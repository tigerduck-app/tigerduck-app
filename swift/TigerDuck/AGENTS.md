# App target

Rules for `swift/TigerDuck/`, the iOS app and its native macOS build. Read
`Services/AGENTS.md`, `Services/Migrations/AGENTS.md` and `LiveActivity/AGENTS.md` before
working in those directories.

## Conventions

- Add no new responsibilities to `AppState`; feature state lives in the feature's view model or
  service. Features read auth and protected-access state from `AppState` instead of keeping
  their own copy.
- Feature view models are `@Observable` and show cached data first; app launch or an explicit
  refresh does the network fetch.
- Cross-feature updates go through the `NotificationCenter` names in `AppConstants`
  (`dataDidUpdate`, `liveActivityPreferencesDidChange`, `languageDidChange`, ...). There is no
  dependency-injection container or store framework.
- Styling goes through `TigerDuckTheme`, `VisualPreset` and `VisualStylePolicy`.
- Day and class-time math uses the Taipei calendar (`AppConstants.taipeiCalendar`), never
  `Calendar.current`. Schedule-sensitive code reads the time through `Clock/AppClock`, so the
  debug clock override applies.
- Persistence is split: SwiftData models in `Models/SwiftData/` and JSON caches in
  `Services/Core/DataCache.swift`.
- Code the Watch app also needs goes in `swift/Shared/`, which both targets compile. The widget
  extensions do not compile it and keep their own copies, such as `WidgetTaipei`.

## Anti-patterns

- Do not gate protected NTUST screens on cookie validity or on `isNTUSTLoggedIn` alone; silent
  re-auth is expected. Use `ntustProtectedAccessState(isEmpty:)`.
- Do not write the previous user's data back after logout. Bridge and service code check the
  login generation and cancellation before writing.
- Do not trigger a Live Activity refresh for presentation-only changes such as `visualPreset`.
- Do not add one-off spacing or color systems next to the shared theme.
- Do not add a file without assigning it a platform for the macOS build (see the root
  AGENTS.md).

## Tests

- Unit tests are in `swift/TigerDuckTests/` (Swift Testing and XCTest) and run in CI on every
  pull request to `main` and `dev`. UI tests in `swift/TigerDuckUITests/` do not run in CI.

## Gotchas

- `Bridge/ModelAdapters.swift` is an empty placeholder from a planned KMP integration; nothing
  uses it.
- macOS sidebar pins are stored in `macConfiguredTabs`, apart from the iOS tab configuration.
