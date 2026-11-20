# School

Rules for `swift/TigerDuck/School/`: NTUST sign-in and sessions, Moodle, the library, the
school's pages and their parsers, and the TLS pins of the school's hosts.

## Conventions

- NTUST-protected requests use `NTUSTSessionManager.shared`, the browser-like session whose
  cookie jar lives in the App Group, so the SSO session outlives a relaunch.
- Sign in lazily. Only a fetch that needs a service's page logs in, and `ensureAuthenticated`
  renews the SSO session alone. SSO logins queue through `SSOLoginService.oneAtATime`, and
  automatic posts of the stored password, an SSO sign-in's or a Moodle token renewal's, through
  `SchoolPasswordPosts.postingStoredPassword`; a sign-in the user typed does not wait for it.
- School answers are kept for a while and shared between callers (`FreshnessPolicy`); a pull
  fetches them again.

## Anti-patterns

- Keep the service cookies SSO flows hold; clearing every cookie makes the school warn about a
  new device.
- Never invalidate `NTUSTSessionManager.session`: flows keep it, and a request on an invalidated
  session ends the app with an exception. Sign-out calls `cancelTasksAndForgetSignIn()` instead.
- POST a password or a token through `swift/Shared/CredentialPost.swift`, its delegate for
  redirects and its target check for a form a page names. URLSession's default redirect
  handling sends the body again to a 307's or a 308's `Location`.
- A failed TLS pin check (`swift/Shared/TLSPins/`, `Mail/Transport/MailTLSVerifier.swift`) has
  one way around it, the user's Continue on a mismatch whose anchor is in the signed document's
  `prompt_roots`; add no other (docs/decisions/0025-remote-tls-pins.md).
