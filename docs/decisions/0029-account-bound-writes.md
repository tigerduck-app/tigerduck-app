# 0029. A write lands only in the sign-in it was read for

Status: accepted

## Context

ADR 0026 gave each account one `AccountSession` and asked every writer of account data to take
the session's ticket before its first `await` and compare it after the last one. The comparison
stayed the caller's job, so it kept being written again in new shapes: closures returning
`isCurrent`, `currentCheck()`, a `SignInCount` in each auth actor, an epoch in the bulletin list
and in the mailbox pages, a sign-out count in the outbox drain. A write that forgot the check
compiled, and several did: an outbox reply, a backend send replayed after a 401 with the next
account's token, a course reset stamp, the SSO login stamp, a bulletin detail.

## Decision

- `SignIn` (`swift/TigerDuck/Account/AccountSession.swift`) is one sign-in of one account. It
  answers `isCurrent` itself, from any actor, and at most one sign-in of an account is current,
  so two current ones are the same sign-in and nothing compares them by hand. The account's
  sign-out ends it (`AccountSession.endSignIn()`); the signed-out time and the next sign-in share
  the sign-in that follows.
- Work gets its sign-in where it starts, in the places that start account work: `Account/`,
  `App/`, `Features/`, `Platform/`, `Debug/`, `Devices/`, `Backend/Auth/`, `Backend/Sync/`,
  `Mail/Account/`, the mail check, `School/Library/`, the Moodle token and autologin services, and
  `Migrations/`.
  Async work runs as `session.task {}` or `session.withSignIn {}`, or reads `startingSignIn`
  first; a synchronous user action reads `currentSignIn`, which is unavailable in async code.
  Every other layer is handed the `SignIn` as a parameter.
- Every write to a store of account data takes the `SignIn` it was read for, and the store drops a
  write whose sign-in has ended. That covers the `AccountScoped` stores of `SignOutPlan`, the
  observable stores in `Stores/`, and the account-scoped `Defaults` keys of
  `docs/account-state.md`, which only the file that clears them writes (`SyncProgress`,
  `SchoolAccountKeys`, `BrowserSites`, `NotificationSettingsSync`, `CourseFiles`). School Mail's
  fields change only through `MailPreferences.change(for:_:)`, its password with the sign-in it was
  entered for. A value kept in memory for one sign-in is a `SignInBound`, which reads as empty once
  that sign-in has ended. A counter stays only where it counts something other than sign-ins, and
  its name says what: `MailCache.wipeCount`, `BrowserData.storeResets`.
- A request to the TigerDuck backend built from account data carries its `SignIn`
  (`BackendRequest.sent(for:)`). `BackendClient` sends it only with a token of that sign-in, on the
  first send and on the replay after a 401, and the token pair records the sign-in it was issued
  to. A client of account data takes `AuthTokenManager.backendAuth`, whose header names its
  sign-in; only the course catalog's header names none (`BackendAuth.unbound`), and `BackendClient`
  sends no request bound to a sign-in with such a header. `AuthTokenManager` and `MoodleTokenService` use the same `SignIn`, so one type crosses the
  layers.
- `tools/check_architecture.py` fails, from phase 8: a sign-in read outside the places above; a
  sign-in compared by hand, or an old counter type, outside `Account/`, `Backend/Client/` and
  `Backend/Auth/`; a persistence type of an account named outside its store; a write to an
  account-scoped `Defaults` key outside the file `docs/account-state.md` names for it, or to School
  Mail's fields outside `Mail/Store/`; and a header that names no sign-in outside the course
  catalog.

## Consequences

- A write or send of account data without a sign-in does not compile, and the check that drops a
  stale one lives once, in the store or the client.
- A write or send that crosses a sign-out is dropped where it lands, not where it started; the
  work itself still runs to its end unless its session task was cancelled.
- A test makes its own `AccountSession` or `SignInSeries` and ends it to stand for a sign-out.
