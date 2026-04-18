# PROJECT KNOWLEDGE BASE

**Generated:** 2026-04-18 19:18 CST  
**Commit:** 9b56b5b  
**Branch:** dev

## OVERVIEW
TigerDuck is a dual-stack campus assistant: a SwiftUI iOS app in `swift/` and Python NTUST scraping/validation scripts in `backend/`. The app is mobile-first; the backend is a set of standalone CLI-style scripts, not a long-running API server.

## STRUCTURE
```text
./
├── swift/                 # Xcode project, app target, widget target, tests
│   ├── TigerDuck/         # Main app source; see swift/TigerDuck/AGENTS.md
│   ├── TigerDuckLiveActivity/
│   ├── TigerDuckTests/
│   └── TigerDuckUITests/
├── backend/
│   └── api/               # Python fetch/scrape scripts; see backend/api/AGENTS.md
├── docs/                  # Migration notes and design/planning docs
└── README.md              # Product overview, setup, contribution rules
```

## WHERE TO LOOK
| Task | Location | Notes |
|---|---|---|
| App bootstrap | `swift/TigerDuck/TigerDuckApp.swift` | `@main`, SwiftData container, scene refresh behavior |
| Global app state | `swift/TigerDuck/App/AppState.swift` | Auth, settings, live activity, background sync |
| iOS feature work | `swift/TigerDuck/` | Start in `swift/TigerDuck/AGENTS.md` |
| Service/auth work | `swift/TigerDuck/Services/` | See child AGENTS for auth/network/logging boundaries |
| Live Activity work | `swift/TigerDuck/LiveActivity/` | Separate subsystem with its own invariants |
| Backend scraping work | `backend/api/` | Standalone Python entry scripts, `.env`-driven |
| Product/setup context | `README.md` | Includes local setup, architecture sketch, contribution checklist |

## CODE MAP
| Symbol | Type | Location | Refs | Role |
|---|---|---|---:|---|
| `TigerDuckApp` | struct | `swift/TigerDuck/TigerDuckApp.swift` | — | App entry, SwiftData bootstrapping |
| `AppState` | class | `swift/TigerDuck/App/AppState.swift` | high | App orchestration and shared state |
| `HomeViewModel` | class | `swift/TigerDuck/Features/Home/HomeViewModel.swift` | feature-local | Home dashboard state |
| `AuthService` | class | `swift/TigerDuck/Services/Auth/AuthService.swift` | shared | NTUST auth + silent reauth |
| `NTUSTSessionManager` | class | `swift/TigerDuck/Services/Network/NTUSTSessionManager.swift` | shared | Shared URLSession + cookie TTL |
| `LiveActivityCoordinator` | class | `swift/TigerDuck/LiveActivity/Runtime/LiveActivityCoordinator.swift` | subsystem | ActivityKit lifecycle |
| `NtustSsoBridge` | class | `backend/api/ntust_sso.py` | backend-core | Python SSO/session foundation |

## CONVENTIONS
- iOS app work is centered on `@Observable` state objects plus SwiftUI views; shared app-wide coordination belongs in `AppState`, not per-feature duplicated logic.
- Auth gating is cached-first: screens should derive NTUST access from `AppState.ntustProtectedAccessState(isEmpty:)`, not from cookie validity alone.
- Python backend uses `uv` (`backend/pyproject.toml`, `uv.lock`) and environment variables from `backend/api/.env` / `.env.template`.
- Test surface is split by Xcode targets: `swift/TigerDuckTests` for unit tests, `swift/TigerDuckUITests` for UI tests. There is currently no backend test suite.

## ANTI-PATTERNS (THIS PROJECT)
- Do not treat `backend/api/bulletin/pages/` as source code; it is scraped markdown data and will distort search/scoring.
- Do not trigger Live Activity refreshes for pure presentation changes like `visualPreset`; `AppState` explicitly keeps those concerns separate.
- Do not gate protected NTUST screens directly on cookie validity; silent re-auth is expected.
- Do not assume a web backend exists here; the Python side is a toolbox of scripts.

## UNIQUE STYLES
- The repo is markdown-heavy because bulletin scraper output is versioned alongside code.
- The iOS app uses a distinct Live Activity subsystem plus a separate widget extension target.
- The Swift app mixes SwiftData persistence with JSON/user-scoped caches in `DataCache` rather than relying on a single storage mechanism.

## COMMANDS
```bash
open swift/TigerDuck.xcodeproj
xcodebuild test -project swift/TigerDuck.xcodeproj -scheme TigerDuck -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
cd backend && uv sync
```

## NOTES
- `swift/buildServer.json` points tooling at the `TigerDuck` scheme and Xcode build server workspace.
- Current Xcode targets: `TigerDuck`, `TigerDuckTests`, `TigerDuckUITests`, `TigerDuckLiveActivityExtension`.
- There is no repo-level GitHub Actions pipeline at the moment; verification is local/manual.
