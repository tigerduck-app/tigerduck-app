# 0007. Isolate the developer mail server override from the school account

Status: accepted

## Context

In DEBUG builds only, `Settings → Developer → Email` points School Mail at another IMAP and SMTP
server. No School Mail state records which server it came from: `MailCache` is keyed by folder
and UID, `MailListViewModel` holds folder roles and pages, and the new-mail marker sits in
`Defaults`, so after a switch the test mailbox would show the old server's mail with Delete
attached. While the school configuration is applied, the saved password is the school
account's and must never reach another server. And `MailAccountManager.LoginError` reduces every
failure to one of five sentences: a name that does not resolve, a refused port and a filtered one
all read "Can't reach the mail server".

## Decision

- `DevMailServerSettings` (`swift/TigerDuck/Debug/DevMailServerOverride.swift`) commits every
  change. A change to the effective configuration signs School Mail out through
  `MailAccountManager.logout()`, which clears the saved password, cache, new-mail markers,
  diagnostics and `authFailed` lockout; its `onSignedOut` hook stops background refresh and
  removes delivered mail notifications. The lockout goes with the password it was about: kept,
  it would follow to a server that rejected nothing; cleared alone, it would let that password
  be retried. A save that resolves to the same configuration signs nobody out, and `generation`
  lets the School Mail page drop what it resolved against the old server.
- `DevMailConnectionProbe.credentials(username:password:appliedIsOverridden:)` offers the saved
  password only while an override is applied. `DevMailServerSettings.applyRefusal(for:)`, checked
  again in `commit`, keeps that true by refusing an override that names a school host (the
  configured school host or any host in the TLS pin table). `MailServerConfig.resolve(override:)`
  only holds such a host at implicit TLS, so after a sign-in under it Test connection would offer
  the school password elsewhere. `DevMailConnectionProbe.refusal(for:)` never tests a school host.
- Credentials typed on the screen are used as typed and kept only in view state, since a failed
  sign-in saves no password for AUTH to try. A blank password falls back to the saved one, scoped.
- Test connection probes the draft, since applying signs out, in stages that each report the
  error actually thrown: DNS, TCP, implicit TLS, CONNECT (SwiftMail with `MailTLSVerifier` as
  `LiveMailClient` installs it, which covers STARTTLS) and AUTH. It uses its own connections and,
  beyond reading the saved credentials, never touches `MailAccountManager`, the cache or the
  credential store.

## Consequences

- Switching servers always costs a sign-out, and the screen says so before Apply.
- Any new way to commit an override must go through `DevMailServerSettings.commit`.
- `DevMailConnectionProbeTests` and `MailServerConfigTests` pin the refusals, the credential
  scoping and the reset.
