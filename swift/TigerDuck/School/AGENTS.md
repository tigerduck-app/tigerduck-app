# School

Rules for `swift/TigerDuck/School/`: NTUST sign-in and sessions, Moodle, the library, the
school's pages and their parsers, and the TLS pins of the school's hosts.

## Conventions

- NTUST-protected requests use `NTUSTSessionManager.shared`, the browser-like session with its
  own cookie jar; do not create another `URLSession` for them. The jar lives in the App Group, so
  the SSO session outlives a relaunch.
- Sign in lazily. Only a fetch that needs a service's page logs in, and `ensureAuthenticated`
  renews the SSO session alone. SSO logins queue through `SSOLoginService.oneAtATime`, and
  automatic posts of the stored password, an SSO sign-in's or a Moodle token renewal's, through
  `SSOLoginService.postingStoredPassword`; a sign-in the user typed does not wait for it.
- School answers are shared: `MoodleEnrolledCoursesService` keeps one per wstoken for a minute,
  `MoodleSiteInfoService` keys the user id by token, and `CourseLookupService` keeps lookups for
  30 minutes. A pull skips them.

## Anti-patterns

- Do not clear every cookie during SSO flows; some service cookies are kept so the school does
  not warn about a new device.
- Do not invalidate `NTUSTSessionManager.session`: flows keep it, and a request on an
  invalidated session ends the app with an exception. Sign-out cancels its tasks and moves
  `generation`, which `SSOLoginService` checks before each POST.
- Do not POST a password or a token with URLSession's default redirect handling, which sends
  the body again to a 307's or a 308's `Location`. Use `swift/Shared/CredentialPost.swift`: its
  delegate for redirects, and its target check for a form a page names.
- Do not add a way around a failed TLS pin check (`swift/Shared/TLSPins/`,
  `Mail/Transport/MailTLSVerifier.swift`) other than the user's Continue on a mismatch whose
  anchor is in the signed document's `prompt_roots`, which trusts the leaf and intermediates for
  one build. Pins only narrow system trust, and once a set expires the check falls back to system
  trust by design (docs/decisions/0025-remote-tls-pins.md).

## Gotchas

- Each school service keeps its server session behind a cookie that ends with the app. A visit
  with only the service's persisted sign-in cookie signs the account out of SSO, so
  `NTUSTSessionManager` drops every non-SSO cookie at launch.
- A lapsed service session sends a page to the campus portal, `i.ntust.edu.tw`, not to ssoam2.
  The course list and score fetches treat any final host but their own as a bounce: they drop
  that service's cookies and sign in again.
- These clients follow NTUST and Moodle page behavior closely, so a parser change can affect
  several features even when one screen seems involved.
