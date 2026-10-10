# Services

Rules for `swift/TigerDuck/Services/`: NTUST auth and sessions, the per-domain API clients,
School Mail, the TigerDuck backend clients, Watch sync, caches and logging.

## Conventions

- `AuthService` coordinates auth. It tells cookie-valid auth apart from stored credentials, and
  keeps credentials through silent re-auth failures.
- NTUST-protected requests use `NTUSTSessionManager.shared`, the browser-like session with its
  own cookie jar; do not create another `URLSession` for them. The jar lives in the App Group, so
  the SSO session outlives a relaunch.
- Sign in lazily. Only a fetch that needs a service's page logs in, and `ensureAuthenticated`
  renews the SSO session alone. SSO logins queue through `SSOLoginService.oneAtATime`.
- School answers are shared: `MoodleEnrolledCoursesService` keeps one per wstoken for a minute,
  `MoodleSiteInfoService` keys the user id by token, and `CourseLookupService` keeps lookups for
  30 minutes. A pull skips them.
- Services write fetched results through `DataCache`, so features and background sync read the
  same persisted data.
- New TigerDuck backend clients copy the request construction, auth header and error handling
  of `Push/PushAPIClient.swift`, as `Sync/SettingsDocumentClient.swift` does. Cloud sync reaches
  the backend through `PushCoordinator`.
- Logging goes through `AppLogger`, which scrubs URLs and breadcrumbs before they reach Sentry;
  do not use `print`.

## Anti-patterns

- Do not clear every cookie during SSO flows; some service cookies are kept so the school does
  not warn about a new device.
- Do not call `AuthService.login` to re-authenticate silently: it harvests a new Moodle token
  and drops the course cache. The Moodle token renews itself on `.invalidToken`.
- Do not ignore logout races; in-flight writes check cancellation and the login generation.
- Do not invalidate `NTUSTSessionManager.session`: flows keep it, and a request on an
  invalidated session ends the app with an exception. Sign-out cancels its tasks and moves
  `generation`, which `SSOLoginService` checks before each POST.
- Do not store secrets in `UserDefaults`; credentials live in the Keychain.
- Do not route School Mail through the TigerDuck backend. The phone talks to the school's mail
  server directly, and the mail password stays on the device (`Mail/Store/MailCredentialStore.swift`).
- Do not add a way around a failed TLS pin check (`TLSPinningDelegate`,
  `Mail/Transport/MailTLSVerifier.swift`). Once a pin set expires, the check falls back to
  system trust by design.
- Do not reference `Migrations/` types from feature services.

## Gotchas

- `DataCache.clearUserScopedData()` is a privacy boundary: logout purges the previous user's
  data before another login can use the app.
- `NetworkMonitor` is observable state; some refresh paths read it before fetching.
- Each school service keeps its server session behind a cookie that ends with the app. A visit
  with only the service's persisted sign-in cookie signs the account out of SSO, so
  `NTUSTSessionManager` drops every non-SSO cookie at launch.
- A lapsed service session sends a page to the campus portal, `i.ntust.edu.tw`, not to ssoam2.
  The course list and score fetches treat any final host but their own as a bounce: they drop
  that service's cookies and sign in again.
- `Push/ScheduleSyncService.swift` builds the 48-hour event list it sends to the backend with
  the Live Activity resolvers, so a resolver change also changes what the server pushes.
- Services follow NTUST and Moodle page behavior closely, so a parser change can affect several
  features even when one screen seems involved.
- A `410 Gone` from the TigerDuck backend latches `API/APIVersionGate.swift` for good, and the
  app asks the user to update. Only backend clients report to it; a 410 from the school's
  servers means a page moved.
- `MailCredentialStore` is the one Keychain item readable after first unlock
  (`.afterFirstUnlockThisDeviceOnly`), because new-mail checks run in Background App Refresh
  while the phone is locked. Everything else uses `SecureStore`'s `.whenUnlockedThisDeviceOnly`.
- School Mail is hidden on macOS (`Mail/Core/SchoolMailAvailability.swift`), and its sources are
  left out of the Mac build.
