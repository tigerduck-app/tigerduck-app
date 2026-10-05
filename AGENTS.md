# PROJECT KNOWLEDGE BASE

**Generated:** 2026-04-18 19:18 CST  
**Updated:** 2026-10-05 (commit 42b8f21, v2.3.0)  
**Branch:** dev

## OVERVIEW
TigerDuck is an NTUST campus assistant. This repo holds the Apple clients — a SwiftUI iOS app with a native macOS build, an Apple Watch app, and widget / Live Activity extensions — all in `swift/`, plus `api-poc/`, Python scripts that probe NTUST / Moodle endpoints before the Swift client implements them. The production push / sync backend (FastAPI + APNs) lives in a separate repo, `tigerduck-app/tigerduck-backend`; the app reaches it over `https://api.tigerduck.app/v3/*`.

## STRUCTURE
```text
./
├── swift/                       # Xcode project and every Apple target
│   ├── TigerDuck/               # Main app source (iOS + native macOS); see swift/TigerDuck/AGENTS.md
│   ├── TigerDuckLiveActivity/   # Live Activity / Dynamic Island extension UI
│   ├── TigerDuckWidgets/        # iOS / macOS home and lock screen widgets
│   ├── TigerDuckWatch Watch App/  # Apple Watch app
│   ├── TigerDuckWatchWidget/    # Watch complication sources (not referenced by project.pbxproj; no target builds them)
│   ├── Shared/                  # Compiled into both the phone app and the Watch app (Watch wire format, VisualPreset, TaipeiCalendar, TLS pinning)
│   ├── Packages/SwiftMail/      # Vendored IMAP/SMTP package used by School Mail; see its VENDORED.md
│   ├── TigerDuckTests/  TigerDuckUITests/  TigerDuckWatch Watch AppTests/
│   └── ci_scripts/              # Xcode Cloud post-clone hook (fetches submodules)
├── api-poc/                     # Python endpoint probes; see api-poc/api/AGENTS.md
├── app-translation/             # git submodule: localized strings, symlinked into the *.lproj folders
├── name-abbr/                   # git submodule: course / classroom abbreviation dictionaries
├── tools/                       # Localization, licence and macOS source-membership check scripts
├── .github/workflows/           # PR gates (unit tests, version bump, What's New, localization, licences, ...)
├── docs/                        # Migration notes and planning docs
└── README.md / README.en.md     # Product overview, release history, setup, contribution rules
```

## WHERE TO LOOK
| Task | Location | Notes |
|---|---|---|
| App bootstrap | `swift/TigerDuck/TigerDuckApp.swift` | `@main`, SwiftData container, scene refresh behavior |
| Global app state | `swift/TigerDuck/App/AppState.swift` + `AppState+*.swift` | Auth, settings, live activity, push, cloud sync; split by concern into extensions |
| iOS feature work | `swift/TigerDuck/Features/` | Start in `swift/TigerDuck/AGENTS.md` |
| Service/auth work | `swift/TigerDuck/Services/` | See `Services/AGENTS.md` for auth/API/mail/push boundaries |
| School Mail | `swift/TigerDuck/Services/Mail/`, `Features/SchoolMail/` | iOS only; talks IMAP/SMTP to the school directly |
| Live Activity work | `swift/TigerDuck/LiveActivity/` | Separate subsystem with its own invariants |
| Watch app | `swift/TigerDuckWatch Watch App/`, `swift/Shared/Watch/`, `Services/Watch/` | Phone pushes schedule + library credentials over WatchConnectivity |
| macOS-only surfaces | `swift/TigerDuck/Platform/Mac/` | macOS compiles an allow-list (`INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]` in `project.pbxproj`) |
| What's New / releases | `swift/TigerDuck/whatsnew.json`, `Features/Updates/` | Use the `release-bump` skill (`.claude/skills/release-bump/`) to bump versions |
| Endpoint probing | `api-poc/api/` | Standalone Python modules, `.env`-driven |
| Product/setup context | `README.md` | Includes local setup, project structure, contribution checklist |

## CODE MAP
| Symbol | Type | Location | Refs | Role |
|---|---|---|---:|---|
| `TigerDuckApp` | struct | `swift/TigerDuck/TigerDuckApp.swift` | — | App entry, SwiftData bootstrapping |
| `AppState` | class | `swift/TigerDuck/App/AppState.swift` | high | App orchestration and shared state |
| `HomeViewModel` | class | `swift/TigerDuck/Features/Home/HomeViewModel.swift` | feature-local | Home dashboard state |
| `AuthService` | class | `swift/TigerDuck/Services/Auth/AuthService.swift` | shared | NTUST auth + silent reauth |
| `NTUSTSessionManager` | class | `swift/TigerDuck/Services/API/NTUST/NTUSTSessionManager.swift` | shared | Shared URLSession + private NTUST cookie jar |
| `LiveActivityCoordinator` | class | `swift/TigerDuck/LiveActivity/Runtime/LiveActivityCoordinator.swift` | subsystem | ActivityKit lifecycle |
| `NtustSsoBridge` | class | `api-poc/api/ntust/sso.py` | poc-core | Python SSO/session foundation |

## CONVENTIONS
- iOS app work is centered on `@Observable` state objects plus SwiftUI views; shared app-wide coordination belongs in `AppState`, not per-feature duplicated logic.
- Auth gating is cached-first: screens should derive NTUST access from `AppState.ntustProtectedAccessState(isEmpty:)`, not from cookie validity alone.
- One-time upgrade compatibility code goes only in `swift/TigerDuck/Services/Migrations/` (see its AGENTS.md).
- Python in `api-poc/` uses `uv` (`api-poc/pyproject.toml`, `uv.lock`) and credentials from `api-poc/api/.env` (template: `.env.template`).
- Test surface is split by Xcode targets: `TigerDuckTests` (phone unit tests), `TigerDuckWatch Watch AppTests` (watch), `TigerDuckUITests` (UI, not run in CI). There is no Python test suite.

## ANTI-PATTERNS (THIS PROJECT)
- Do not edit the `*.lproj` files under `swift/`; they are symlinks into the `app-translation` submodule, which takes its own PRs.
- Do not treat `api-poc/api/runtime/` (e.g. `bulletin_pages/`) as source; it is gitignored scraper output.
- Do not trigger Live Activity refreshes for pure presentation changes like `visualPreset`; `AppState` explicitly keeps those concerns separate.
- Do not gate protected NTUST screens directly on cookie validity; silent re-auth is expected.
- Do not look for a web backend here; it lives in `tigerduck-backend`, and `api-poc/` is a toolbox of probe scripts.
- Do not add a Swift file to the app target without assigning it a platform: either add it to both `INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]` arrays in `project.pbxproj` (Debug and Release) or list it in `tools/macos-excluded-sources.txt`. The `macOS source membership` workflow fails otherwise.

## UNIQUE STYLES
- The iOS app uses a distinct Live Activity subsystem plus separate widget and Watch app targets; cross-target code lives in `swift/Shared/`.
- The Swift app mixes SwiftData persistence with JSON/user-scoped caches in `DataCache` rather than relying on a single storage mechanism.
- Localization covers 67 locales and is generated in the `app-translation` submodule; What's New feature-page copy is the exception, written in zh-Hant and English in the app.

## COMMANDS
```bash
git submodule update --init --recursive   # required before the first build
open swift/TigerDuck.xcodeproj
xcodebuild test -project swift/TigerDuck.xcodeproj -scheme TigerDuck -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TigerDuckTests
xcodebuild test -project swift/TigerDuck.xcodeproj -scheme 'TigerDuckWatch Watch App' -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)'
cd api-poc && uv sync
```

## NOTES
- Current Xcode targets: `TigerDuck`, `TigerDuckTests`, `TigerDuckUITests`, `TigerDuckLiveActivityExtension`, `TigerDuckWidgetsExtension`, `TigerDuckWatch Watch App`, `TigerDuckWatch Watch AppTests`, `TigerDuckWatch Watch AppUITests`.
- GitHub Actions gate PRs to `main` / `dev`: `tests.yaml` runs the phone and watch unit tests on a `macos-26` runner in the Asia/Taipei timezone; other workflows check the version bump, the What's New entry, localization keys, licences, submodule pins and macOS source membership.
