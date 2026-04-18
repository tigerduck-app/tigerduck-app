# TIGERDUCK APP KNOWLEDGE BASE

## OVERVIEW
`swift/TigerDuck/` is the main iOS app target: bootstrap, app state, features, services, models, theme, and shared UI all live here.

## STRUCTURE
```text
swift/TigerDuck/
├── App/             # app-wide state, constants, login sheet host
├── Bridge/          # KMP/service bridge and adapters
├── Features/        # user-facing tabs and onboarding
├── LiveActivity/    # ActivityKit + reminder subsystem
├── Models/          # Domain + SwiftData models
├── Services/        # Auth, network, logging
├── SharedUI/        # reusable cross-feature views
├── Theme/           # design tokens + visual preset system
├── ContentView.swift
└── TigerDuckApp.swift
```

## WHERE TO LOOK
| Task | Location | Notes |
|---|---|---|
| App entry | `TigerDuckApp.swift` | `@main`, SwiftData schema, foreground refresh hooks |
| Root routing | `ContentView.swift` | Onboarding vs main tabs |
| Shared state / auth / settings | `App/AppState.swift` | Highest-centrality file in app target |
| Feature UI work | `Features/` | `Home`, `ClassTable`, `Calendar`, `Announcements`, `Library`, `Settings`, `More`, `Onboarding` |
| Shared styling | `Theme/` | Course colors, spacing, card/glass modifiers, visual presets |
| Shared components | `SharedUI/` | Login gates, empty states, banners, widgets |
| KMP/native fetch bridge | `Bridge/KMPServiceBridge.swift` | Handles fetch orchestration and logout race safety |

## CONVENTIONS
- Feature view models are `@Observable` and usually load cached data first, with app launch or explicit refresh paths doing the network fetch later.
- Cross-feature sync relies on `NotificationCenter` (`dataDidUpdate`, `liveActivityPreferencesDidChange`) rather than a heavier DI/store framework.
- App-wide sheet presentation and protected-access decisions belong in `AppState`; avoid duplicating auth/login state in feature-local view code.
- Theme usage is centralized through `TigerDuckTheme`, `VisualPreset`, and `VisualStylePolicy`; views are expected to consume those shared surfaces.

## ANTI-PATTERNS
- Do not re-derive NTUST protected access from `isNTUSTLoggedIn` alone; use `ntustProtectedAccessState(isEmpty:)`.
- Do not write previous-user data back after logout; bridge/service code uses login-generation and cancellation guards for that reason.
- Do not bypass shared theme/style helpers with one-off spacing/color systems unless intentionally introducing a new global pattern.

## TEST SURFACES
- Unit tests live in `swift/TigerDuckTests/`.
- UI tests live in `swift/TigerDuckUITests/`.
- Current substantive coverage is concentrated in `TimeSliderViewModelTests.swift`; most features are still lightly tested.

## CHILD GUIDES
- `Services/AGENTS.md` for auth/network/logging work.
- `LiveActivity/AGENTS.md` for ActivityKit, reminders, and timeline logic.

## NOTES
- `Bridge/ModelAdapters.swift` is still sparse; the bridge layer is present ahead of fuller KMP integration.
- `Theme/`, `SharedUI/`, and `App/` are support layers with high reuse but should usually be understood in the context of feature/service changes rather than treated as isolated products.
