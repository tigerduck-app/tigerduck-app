# Migrations

One-time upgrade code goes here: a new shape of stored data (Keychain, UserDefaults, SwiftData,
JSON cache), a bootstrap existing users need once, or leftovers of an earlier version to clean
up. Retry and refresh policies and new features belong with the feature.

1. The `migration` rule of `tools/check_architecture.py` checks the file shape: one migration
   per file named for its type, its static `runIfNeeded()`, its private `<Name>.v1.done` key, and
   no references between migrations or from outside the folder except `AppEnvironment`.
2. Each migration owns its failure handling, and its done key lives in
   `AppUserDefaults.standard`, so deleting the file removes it.
3. `AppEnvironment.runPendingMigrations()` runs them once per launch from `AppEnvironment.init()`;
   one that moves Keychain items launch code reads runs earlier there, before `AuthService` is
   built. One that finds protected data unreadable, as on a locked phone, may run itself again
   once it becomes readable, since unlocking resumes the process instead of launching it again.
4. A migration stays until every production user has run it. Then delete its file and its call
   in `runPendingMigrations()`; its flag may stay behind.
