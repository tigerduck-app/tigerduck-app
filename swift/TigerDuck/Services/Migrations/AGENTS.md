# Migrations

Compatibility code for breaking changes goes in this folder and nowhere else.

## Rules

1. One migration per Swift file, with no references between files in this folder.
2. Each migration owns its done flag, its static `runIfNeeded()` entry point and its failure
   handling. The flag is a private `<Name>.v1.done` UserDefaults key declared in the same file,
   so deleting the file removes it. `MoodleTokenMigration` predates this rule and keeps its flag
   as a Defaults key in `AppDefaults.swift`.
3. `AppState.runPendingMigrations()` runs them, once per launch, from `AppState.init()`.
4. Feature services (`AuthService`, `MoodleAssignmentService`, `MoodleTokenService`, ...) must
   not reference types declared here.
5. Name files `<Subject><Action>Migration.swift`, for example `MoodleTokenMigration` or
   `DefaultTabsPinMigration`.

## When a migration belongs here

- The shape of stored data changes (Keychain, UserDefaults, SwiftData, JSON cache).
- Existing users need a one-time bootstrap on upgrade.
- A previous version left artifacts that need cleaning up.

Regular feature code, ongoing runtime policies such as retry or refresh, and new features do not
belong here, and feature code never calls into this folder.

## Lifecycle

A migration stays until every production user has run it, typically two to three release
cycles. Then delete the whole file and its call in `runPendingMigrations()`; do not leave an
empty shell. Its UserDefaults flag can stay as a harmless orphan or be cleaned up by a later
migration.
