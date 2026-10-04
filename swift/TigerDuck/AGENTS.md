# TIGERDUCK APP KNOWLEDGE BASE

## OVERVIEW
`swift/TigerDuck/` is the main app target, built for iOS and as a native macOS app: bootstrap, app state, features, services, models, theme, and shared UI all live here.

## STRUCTURE
```text
swift/TigerDuck/
├── App/             # AppState (+ AppState+*.swift extensions), constants, defaults, push/notification delegates, login sheet host
├── Bridge/          # AppServiceBridge: fetch orchestration between services and SwiftData
├── Clock/           # AppClock, minute ticker, timezone observer, debug clock override
├── Debug/           # Developer menu: endpoint overrides, triggers, sample What's New flow
├── Extensions/      # Small Foundation / SwiftUI extensions
├── Features/        # User-facing tabs, onboarding, update prompt + What's New
├── LiveActivity/    # ActivityKit subsystem (app side)
├── Models/          # Domain/ + SwiftData/ models
├── Platform/Mac/    # macOS-only scenes and layouts
├── Services/        # Auth, API clients, mail, push, cloud sync, watch sync, migrations
├── Shared/          # App-level helpers (AppVersion, AppURLs, class table layout, small components)
├── SharedUI/        # Reusable cross-feature views
├── Theme/           # Design tokens, card/glass/surface modifiers, VisualStylePolicy
├── Widgets/         # Builds and writes the snapshot the widget extension reads
├── whatsnew.json    # Per-release What's New summaries
├── ContentView.swift
└── TigerDuckApp.swift
```
`VisualPreset`, `NetworkMonitor`, `TLSPinningDelegate` and `TaipeiCalendar` live one level up in `swift/Shared/`, which the phone app and the Watch app both compile. The widget extensions are not members of it and keep their own copies where needed (e.g. `WidgetTaipei`).

## WHERE TO LOOK
| Task | Location | Notes |
|---|---|---|
| App entry | `TigerDuckApp.swift` | `@main`, SwiftData schema, foreground refresh hooks |
| Root routing | `ContentView.swift` | Onboarding vs main tabs |
| Shared state / auth / settings | `App/AppState.swift`, `App/AppState+*.swift` | Highest-centrality files in the app target |
| Feature UI work | `Features/` | `Home`, `ClassTable`, `Calendar`, `Bulletins`, `Score`, `Library`, `SchoolMail`, `More`, `Settings`, `Onboarding`, `Updates` |
| Update prompt / What's New | `Features/Updates/`, `whatsnew.json` | Feature pages + per-release summary; replayable from Settings |
| Shared styling | `Theme/`, `swift/Shared/Theme/VisualPreset.swift` | Course colors, spacing, card/glass modifiers, visual presets |
| Shared components | `SharedUI/` | Login gates, empty states, banners, widgets |
| Fetch bridge | `Bridge/AppServiceBridge.swift` | Fetch orchestration and logout race safety |
| macOS layouts | `Platform/Mac/` | Sidebar navigation; sidebar pins are stored apart from the iOS tab config |

## CONVENTIONS
- Feature view models are `@Observable` and usually load cached data first, with app launch or explicit refresh paths doing the network fetch later.
- Cross-feature sync relies on `NotificationCenter` (`AppConstants.dataDidUpdate`, `liveActivityPreferencesDidChange`, `languageDidChange`, ...) rather than a heavier DI/store framework.
- App-wide sheet presentation and protected-access decisions belong in `AppState`; avoid duplicating auth/login state in feature-local view code.
- Theme usage is centralized through `TigerDuckTheme`, `VisualPreset`, and `VisualStylePolicy`; views are expected to consume those shared surfaces.
- Day / class-time math uses the Taipei calendar (`AppConstants.taipeiCalendar`, from `swift/Shared/TaipeiCalendar.swift`), never `Calendar.current`; schedule-sensitive code reads the time through `Clock/AppClock` so the debug clock override applies.

## ANTI-PATTERNS
- Do not re-derive NTUST protected access from `isNTUSTLoggedIn` alone; use `ntustProtectedAccessState(isEmpty:)`.
- Do not write previous-user data back after logout; bridge/service code uses login-generation and cancellation guards for that reason.
- Do not bypass shared theme/style helpers with one-off spacing/color systems unless intentionally introducing a new global pattern.
- Do not add a file here without assigning it a platform for the macOS build (see root `AGENTS.md`).

## TEST SURFACES
- Unit tests live in `swift/TigerDuckTests/` (Swift Testing + XCTest), with subfolders for `Clock`, `SchoolMail`, `Watch` and `Widgets`. CI runs them on every PR to `main` / `dev`.
- UI tests live in `swift/TigerDuckUITests/`; CI does not run them.
- Coverage is broad but uneven: migrations, notification settings sync, push registration, What's New, School Mail and Live Activity have dedicated suites; most views do not.

## CHILD GUIDES
- `Services/AGENTS.md` for auth, API, mail, push and sync work.
- `Services/Migrations/AGENTS.md` before adding any upgrade-compatibility code.
- `LiveActivity/AGENTS.md` for ActivityKit, reminders, and timeline logic.

## NOTES
- `Bridge/ModelAdapters.swift` is an empty placeholder left from a planned KMP integration that never landed; nothing uses it.
- `Theme/`, `SharedUI/`, and `App/` are support layers with high reuse but should usually be understood in the context of feature/service changes rather than treated as isolated products.
