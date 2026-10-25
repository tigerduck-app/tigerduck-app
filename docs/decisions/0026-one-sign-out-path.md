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

- `AppState.logoutNTUST()` is the one sign-out path. The Settings and Mac buttons call it, and a
  sign-in as another student runs it through `AuthService.signOutStoredAccount` first. It runs in
  this order:
  1. It stops the account's work in flight: revision polling, the sync task, the shared
     assignment round and the Live Activity refreshes.
  2. It moves the account generation. `AuthService.logout()` deletes the credentials and moves
     `loginGeneration`, and in the same main-actor step `NTUSTSessionManager.generation`;
     `AuthTokenManager.endSession()` and `MoodleTokenService.signOut()` move their own counters
     on their actors and keep nothing a late reply brings.
  3. It clears what the device holds: `AppState.forgetAccountOnDevice` for the stores outside
     `AppState`, then `AppState`'s own lists, and posts `AppConstants.dataDidUpdate` so feature
     view models, widgets and the Watch rebuild from the empty caches.
  4. It starts the calls that need the network, in `AuthService.startSignOutCalls`: forgetting the
     school's pages, settling cloud sync, unregistering the device with the session it kept, ending
     Live Activities and removing the account's notifications. A sign-in waits for them.
- `AuthService.loginGeneration` is the account generation. Code that writes data of the account
  reads it before its first `await` and writes only if it has not moved after the last one. Code
  that cannot reach `AuthService` checks the counter the same sign-out moves for it:
  `NTUSTSessionManager.generation` for school requests, `AuthTokenManager`'s and
  `MoodleTokenService`'s own for their tokens, and the epoch of a store that step 3 clears (the
  bulletin list, classroom usage). School Mail and the library are accounts of their own, with
  their own sign-outs and counters (`MailCache.wipeCount`, `LibraryService.loginGeneration`).
- `docs/account-state.md` lists every store and what clears it, and
  `tools/check_account_state.py` fails CI when a Keychain key, `Defaults` key or `DataCache` file
  is declared without a row, or an account's row names a function that does not clear it.
  `AccountSwitchTests` signs in as one student, fills the stores, signs in as another and finds
  nothing of the first.

## Consequences

- A new store of account data needs a row and a clearer reached from step 3, or a check of the
  account generation before it writes; the check catches the declarations it can read, and the
  table names the stores it cannot.
