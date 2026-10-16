# 0024. Build nothing from stored data in a launch before the first unlock

Status: accepted

## Context

A silent push, a Live Activity push-to-start or a Watch message can launch the app in the
background before the phone's first unlock after a restart. Until then iOS keeps the app's files,
its `UserDefaults` and its after-first-unlock Keychain items closed, and `UserDefaults` answers as
if nothing were stored. `AppState.init` took that for a fresh install: its purge tried to delete
the stored credentials and backend tokens, migrations ran on missing done flags, and a process
that lived on into the user's next open showed onboarding
(https://github.com/tigerduck-app/tigerduck-app/issues/680).

## Decision

- `TigerDuckApp` builds everything that reads stored data (`AppState`, the Watch sync, the widget
  writer, the School Mail bootstrap and the Debug checks) through `AfterFirstUnlock` in
  `swift/TigerDuck/App/AfterFirstUnlock.swift`. A launch after the first unlock builds in
  `TigerDuckApp.init`, as before. A launch before it builds nothing, then builds once at
  `protectedDataDidBecomeAvailableNotification`, at `didBecomeActiveNotification`, or when a scene
  first reads it.
- `FirstUnlock.hasHappened()` tells the two apart by writing a file of the
  `completeUntilFirstUserAuthentication` class, which preferences and the app's files get by
  default. Its key exists only after the first unlock, so the write fails before it.
- A held-back build first asks `FirstUnlock.storedDataReadsBack()`, which reads
  `appHasBeenInstalled`, again after a `synchronize()` if it reads false. A process that started
  before the unlock may keep an empty copy of `UserDefaults` after it. If the flag does not read
  back, the process ends (`exit(0)`) and the next launch starts clean; with a scene up, the app
  closes once and opens as usual at the next tap. A real fresh install never gets here, as its
  first launch comes after an unlock, unless the probe's write fails for another reason, such as a
  full disk; then each open ends until that write goes through.
- School Mail's background refresh asks the same before it reads its preferences, and when the
  answer is no it schedules the next run and checks nothing.

## Alternatives

- `UIApplication.isProtectedDataAvailable`: false behind any lock, not only before the first
  unlock, while the backend session, the device id and the endpoint override are kept readable
  after the first unlock so that background work runs on a locked phone. `UIApplication.shared`
  does not exist yet during `TigerDuckApp.init` either: SwiftUI builds the app first.
- Reading a file instead of writing one: before the first unlock a closed file and a missing one
  look alike.
- Guarding each purge, migration and write in `AppState.init`: a process that lived on would
  still show the settings it read as empty, onboarding among them.
- Building from the empty copy at the late build: its purge would delete the credentials then.

## Consequences

- Launch code that reads `UserDefaults`, the Keychain or the app's files goes inside the closure
  `TigerDuckApp.makeLaunch` hands `AfterFirstUnlock`.
- A held-back process the system wakes for a School Mail run after the unlock, before anything
  built it, checks mail without `SchoolMailBootstrap.install()`: a rejected password stops the
  background checks without the notice until the next open. One that still reads an empty copy
  schedules each run and checks nothing until then.
- Every launch logs to the `Launch` category of `org.ntust.app.TigerDuck`: whether the first
  unlock had happened, whether it started in the background with protected data available, and
  how a held-back build ended. A device check reads them in Console.
