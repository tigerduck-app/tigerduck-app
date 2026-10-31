# 0026. One sign-out path, one account generation

Status: accepted

## Context

Signing out of the school account, or signing in as another student, kept producing one kind of
bug: something of the departing account stayed (a cache file, a list in memory, a reply that
landed after the sign-out, the backend's device registration), or something was cleared that
belonged to no account. Each was fixed where it was found
(https://github.com/tigerduck-app/tigerduck-app/issues/629 lists them), so the next one showed up
somewhere else. Writers checked one of several counters, and nothing listed what an account
leaves on the device.

## Decision

- Each account signs out through a `SignOutPlan` of its own
  (`swift/TigerDuck/Account/SignOutPlan.swift`), so signing out of one leaves the other two
  alone: the school account (NTUST, Moodle and the TigerDuck backend) through
  `SignOutPlan.school(_:)`, the library through `LibraryService.clearCredentials()` and School
  Mail through `MailAccountManager.logout()`. The Settings and Mac buttons run the school plan,
  and a sign-in as another student runs it through `AuthService.signOutStoredAccount` first.
  A plan runs in this order:
  1. It stops the account's work in flight: the session's scoped tasks and, for the school
     account, revision polling, the sync task, the shared assignment round, Moodle file
     downloads, holiday uploads and the Live Activity refreshes.
  2. It moves the account's `AccountSession` on. For the school account `AuthService.logout()`
     deletes the credentials in the same main-actor step; `AuthTokenManager.endSession()` and
     `MoodleTokenService.signOut()` move their own counts on their actors and keep nothing a late
     reply brings.
  3. It clears every store the account owns: first the plan's static list of `AccountScoped`
     types, each deleting its files and keys by name, so a store this process never built is
     cleared too; then what the stores do not hold, such as `AppState`'s lists. The school plan
     posts `AppConstants.dataDidUpdate`, so feature view models, widgets and the Watch rebuild
     from the empty caches.
  4. It starts the calls that need the departing session. For the school account
     `AuthService.startSignOutCalls` forgets the school's pages, settles cloud sync, unregisters
     the device with the session it kept, ends Live Activities and removes the account's
     notifications; School Mail's plan wipes its cache. The account's next sign-in waits for them.
- `AccountSession` is the account generation: `AccountSession.school`, `AccountSession.library`
  and one in each `MailAccountManager`. Code that writes data of an account takes the session's
  ticket before its first `await`, or runs as one of the session's scoped tasks, and writes only
  while `isCurrent` holds after the last one; code that cannot reach the session gets a
  `currentCheck()`. `AuthTokenManager` and `MoodleTokenService` keep a `SignInCount` on their
  actors, and a store that step 3 clears may keep an epoch of its own (the bulletin list,
  classroom usage, `MailCache.wipeCount`).
- `docs/account-state.md` lists every store and what clears it, and
  `tools/check_account_state.py` fails CI when a Keychain key, `Defaults` key or cache file is
  declared without a row, an account's row names a function that does not clear it, or an
  `AccountScoped` type is in no plan's list. `AccountSwitchTests` fills every store of each
  account, signs one out and finds its stores empty and the other accounts' kept.

## Consequences

- A new store of account data conforms to `AccountScoped`, joins its account's list and gets a
  row, or checks its account's session before it writes; the check catches the declarations it
  can read, and the table names the stores it cannot.
- The launch's retry of a kept unregister is not a sign-out: it clears nothing of an account, and
  only a backend sign-in waits for it.
