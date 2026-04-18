# SERVICES KNOWLEDGE BASE

## OVERVIEW
`Services/` holds the app’s cross-cutting runtime infrastructure: NTUST auth, session/cookie management, API fetchers, cache persistence, connectivity, and logging.

## STRUCTURE
```text
Services/
├── Auth/      # keychain, secure store, SSO/login orchestration
├── Logging/   # AppLogger
└── Network/   # session manager, fetchers, parsers, cache, DTOs
```

## WHERE TO LOOK
| Task | Location | Notes |
|---|---|---|
| NTUST login flow | `Auth/AuthService.swift` | Interactive + silent reauth, login generation tracking |
| Secure credential storage | `Auth/KeychainManager.swift`, `Auth/SecureStore.swift` | Keychain-backed |
| Web auth integration | `Auth/SSOWebAuthSession.swift` | Browser/session handoff |
| Shared HTTP session | `Network/NTUSTSessionManager.swift` | Cookie TTL, UA spoofing, shared URLSession |
| Course / Moodle / calendar / library fetches | `Network/*Service.swift` | Service-per-domain split |
| Cached persisted data | `Network/DataCache.swift` | JSON/user-scoped cache layer |
| Network parsing/models | `Network/HTMLParser.swift`, `*APIModels.swift` | HTML scraping and DTO boundaries |
| Error capture | `Logging/AppLogger.swift` | Sentry-style centralized logging |

## CONVENTIONS
- `AuthService` is the canonical auth coordinator. It distinguishes cookie-valid auth from stored-credential availability and preserves credentials through silent reauth failures.
- `NTUSTSessionManager.shared` is the shared browser-like session surface. Reuse it instead of creating ad hoc `URLSession`s for NTUST-protected requests.
- Services generally write fetched results through `DataCache` so features and background sync paths converge on the same persisted source.
- Logging belongs in `AppLogger`, not `print` statements.

## ANTI-PATTERNS
- Do not clear all cookies indiscriminately during SSO flows; the code intentionally preserves some service cookies to avoid device-change warnings.
- Do not ignore logout race conditions; in-flight writes must honor cancellation / login-generation guards.
- Do not store secrets in `UserDefaults`; credentials live in keychain-backed storage.

## UNIQUE GOTCHAS
- `DataCache.clearUserScopedData()` is a privacy boundary: logout must purge previous-user data before another login can reuse the app.
- `NetworkMonitor` is observable state, not just a helper function; some refresh paths rely on it before fetching.
- The service layer is tightly coupled to NTUST/Moodle scraping behavior, so parser changes can affect multiple features even when only one screen seems involved.
