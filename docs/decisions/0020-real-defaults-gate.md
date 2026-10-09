# 0020. One gate for tests that read or write the real Defaults keys

Status: accepted

## Context

Some suites can observe their subject only through the app's real, process-wide `Defaults` keys:
static keys in `swift/TigerDuck/App/AppDefaults.swift` with no `suite:` argument, which the code
under test reads and writes directly, not through a seam:

- `BulletinPushOptOutMigration`, whose whole job is `pushServerEnabled`, `bulletinPushEnabled` and
  `serverPushUserOptOut`, and the register body and bulletin PATCH of `PushRegistrationService`.
- `PushRegistrationService.updateSyncPreferences()`, with the six sync switches and
  `syncPreferencesPushPending`, and `LiveActivityPreferencesStore`, with its notification settings.
- `DefaultTabsPinMigration`, and `UpdateNotifyCoordinator.checkManually()`, which stamps
  `lastUpdateCheckAt` and, for an unreadable store version, `lastReportedUnparseableStoreVersion`.

Swift Testing runs suites concurrently, and `.serialized` orders one suite's own tests and nothing
else. The push registration tests set these keys and then await the service; a registration alone
waits out a 250 ms debounce. That leaves room for a migration test to reset the same keys underneath
them, observed as `rejectedBulletinPatchDoesNotPersist` failing
`Defaults[.bulletinPushEnabled] == true` in one full-suite run and passing in the next.

## Decision

- `RealDefaultsGate.shared` in `swift/TigerDuckTests/RealDefaultsGate.swift` is one process-wide
  async gate, taken by `withExclusiveRealDefaults(_:)`, which releases it on a throw too.
- Every test that reads or writes those keys runs inside `withExclusiveRealDefaults`, its save and
  restore included, so only one test is ever inside that window.
- The gate is an actor rather than a lock because callers hold it across `await`s.
- `release()` hands the gate straight to the next waiter instead of clearing `isHeld`, so no third
  caller can take it in between and a resumed waiter need not re-check.
- The gate is not reentrant: a `withExclusiveRealDefaults` nested inside it waits forever.

## Alternatives

- `.serialized` alone: it orders one suite's tests, not one suite against another.
- An `NSLock`: held over a suspension, it can be released on a different thread than took it.

## Consequences

- The gate orders only the tests that take it, so a new test that reads or writes these keys goes
  through `withExclusiveRealDefaults` and puts back what it changed. Current users:
  `BulletinPushOptOutMigrationTests`, `PushRegistrationServiceTests`,
  `NotificationSettingsFixtures`, `DefaultTabsPinMigrationTests` and `UpdateCheckTests`.
