# 0017. Prefill the School Mail sign-in from the NTUST sign-in

Status: accepted

## Context

School Mail has its own login to the school's Mail2000 server. A Mail2000 password is set in webmail
and need not match the NTUST SSO one; for the many students whose passwords do match, the prefill
removes the only typing the sign-in asks for. Repeated rejected logins lock the school account and
its campus Wi-Fi, so a mismatch, the expected failure here, must not turn into repeated `LOGIN`s. A
manual rejection does not set `MailAccountManager.authFailed`, so nothing else throttles this path.
In DEBUG builds a developer override can point the app at another mail server
(docs/decisions/0007-dev-mail-server-override.md); in Release `MailServerConfig.effective` is
always `.school`.

## Decision

`swift/TigerDuck/Features/SchoolMail/Components/MailCredentialPrefill.swift` holds one pure
decision, over `AuthService.storedStudentId` and `storedPassword`, that both sign-in surfaces share:
`MailLoginCard`, the signed-out mail page, and `MailLoginSheet`, the sheet that the Settings
account row and the mail page's re-auth banner open.

- It never submits. The user taps Sign in, or does not, so a wrong guess reaches the server only
  because someone chose to send it.
- It does not offer the password the server last rejected. `MailAccountManager.lastRejectedPassword`
  keeps it, because `MailLoginSheet` builds a new `LoginSheet` each time it is presented. Only a
  credentials rejection sets it and only an accepted sign-in clears it; it is never persisted.
- Against the school server it fills only an empty field, so re-seeding keeps half-typed text.
- Under the developer override it offers nothing of the school's, whose password must not reach
  another server. It always clears the password field, and replaces the ID with the server's
  `@domain` only while the ID is empty or still the prefilled one, since an ID is no secret.
  The connection diagnostic follows the same rule
  (docs/decisions/0007-dev-mail-server-override.md).
- It judges the override on every seed, not once at first appearance: the override can be switched
  on while a signed-out mail screen keeps its state, so `MailLoginCard` also re-seeds when
  `DevMailServerSettings.shared.generation` changes.

## Alternatives

- Prefill nothing: no wrong guess is offered, but many students retype what they share with SSO.
- Prefill and sign in automatically: a mismatched password would send rejected logins nobody chose
  to send, towards the lockout of the account and its Wi-Fi.

## Consequences

- A new sign-in surface takes its fields from `MailCredentialPrefill.fields`, not `AuthService`.
- `swift/TigerDuckTests/SchoolMail/MailCredentialPrefillTests.swift` pins each rule, including an
  override switched on mid-session, a re-cased prefilled ID and a remembered rejection.
