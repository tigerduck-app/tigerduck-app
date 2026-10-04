# SERVICES KNOWLEDGE BASE

## OVERVIEW
`Services/` holds the app’s cross-cutting runtime infrastructure: NTUST auth, session/cookie management, per-domain API clients, School Mail, the TigerDuck push/sync backend clients, Watch sync, cache persistence, logging, and one-time migrations.

## STRUCTURE
```text
Services/
├── API/         # Per-domain clients: NTUST/ (SSO, courses, scores, session), Moodle/, Calendar/, Library/, Bulletin/; AppStoreUpdateService, APIVersionGate
├── Auth/        # AuthService, keychain / SecureStore, SSO web session, AuthTokenManager (backend JWTs)
├── CloudSync/   # Cloud-sync state machine + SyncOutbox of pending local edits
├── Core/        # DataCache, HTMLParser, NameAbbrService
├── Logging/     # AppLogger (Sentry + os.Logger), MainThreadWatchdog
├── Mail/        # School Mail (iOS only): Account, Compose, Core, Rules, Store, Sync, Transport, Demo
├── Migrations/  # One-time upgrade code — read Migrations/AGENTS.md first
├── Push/        # Push-server lifecycle, device registration, schedule sync
├── Sync/        # Settings-document client (`/v3/settings/{namespace}`)
└── Watch/       # WatchConnectivity: schedule + library credential payloads to the Watch app
```
`NetworkMonitor` and `TLSPinningDelegate` live in `swift/Shared/`, which the Watch app also compiles.

## WHERE TO LOOK
| Task | Location | Notes |
|---|---|---|
| NTUST login flow | `Auth/AuthService.swift`, `API/NTUST/SSOLoginService.swift` | Interactive + silent reauth, login generation tracking |
| Secure credential storage | `Auth/KeychainManager.swift`, `Auth/SecureStore.swift` | Keychain-backed |
| Web auth integration | `Auth/SSOWebAuthSession.swift` | Browser/session handoff |
| Shared NTUST HTTP session | `API/NTUST/NTUSTSessionManager.swift` | Private NTUST cookie jar, browser-like UA, shared URLSession |
| Course / score / Moodle / calendar / library fetches | `API/<Domain>/*Service.swift` | Service-per-domain split |
| Cached persisted data | `Core/DataCache.swift` | JSON/user-scoped cache layer |
| Network parsing/models | `Core/HTMLParser.swift`, `API/**/*APIModels.swift` | HTML scraping and DTO boundaries |
| TigerDuck backend auth | `Auth/AuthTokenManager.swift` | v3 JWT access/refresh tokens in the Keychain |
| Push / schedule sync | `Push/PushCoordinator.swift`, `Push/ScheduleSyncService.swift` | 48-hour event list built from the Live Activity resolver |
| Cloud sync | `CloudSync/CloudSyncCoordinator.swift` | Outbox drain with retry; API calls go through `PushCoordinator` |
| Too-old app version | `API/APIVersionGate.swift` | Latches on the backend's `410 Gone` |
| School Mail | `Mail/SchoolMailBootstrap.swift`, `Mail/Transport/LiveMailClient.swift` | IMAP/SMTP via `swift/Packages/SwiftMail` |
| Error capture | `Logging/AppLogger.swift` | Sentry-backed centralized logging |

## CONVENTIONS
- `AuthService` is the canonical auth coordinator. It distinguishes cookie-valid auth from stored-credential availability and preserves credentials through silent reauth failures.
- `NTUSTSessionManager.shared` is the shared browser-like session surface. Reuse it instead of creating ad hoc `URLSession`s for NTUST-protected requests.
- Services generally write fetched results through `DataCache` so features and background sync paths converge on the same persisted source.
- New clients of the TigerDuck backend should follow `Push/PushAPIClient.swift`'s request construction, auth header and error handling, as `Sync/SettingsDocumentClient.swift` does, rather than inventing another networking stack.
- Logging belongs in `AppLogger`, not `print` statements.

## ANTI-PATTERNS
- Do not clear all cookies indiscriminately during SSO flows; the code intentionally preserves some service cookies to avoid device-change warnings.
- Do not ignore logout race conditions; in-flight writes must honor cancellation / login-generation guards.
- Do not store secrets in `UserDefaults`; credentials live in keychain-backed storage.
- Do not route School Mail through the TigerDuck backend; the phone talks to the school's mail server directly, and the mail password stays on this device (`Mail/Store/MailCredentialStore.swift`).
- Do not add a way around a failed TLS pin check (`TLSPinningDelegate`, `Mail/Transport/MailTLSVerifier.swift`); after a pin set's expiry the check falls back to system trust by design.
- Do not reference `Migrations/` types from feature services.

## UNIQUE GOTCHAS
- `DataCache.clearUserScopedData()` is a privacy boundary: logout must purge previous-user data before another login can reuse the app.
- `NetworkMonitor` is observable state, not just a helper function; some refresh paths rely on it before fetching.
- The service layer is tightly coupled to NTUST/Moodle scraping behavior, so parser changes can affect multiple features even when only one screen seems involved.
- `MailCredentialStore` is the one Keychain item readable after first unlock (`.afterFirstUnlockThisDeviceOnly`), because new-mail checks run from Background App Refresh while the phone is locked. Everything else uses `SecureStore`'s `.whenUnlockedThisDeviceOnly`.
- School Mail is hidden on macOS (`Mail/Core/SchoolMailAvailability.swift`), and its sources are excluded from the Mac build.
