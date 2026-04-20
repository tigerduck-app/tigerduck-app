# Migrations — TigerDuck Compatibility Layer

This folder is the ONLY location permitted for breaking-change compatibility code.

## Rules

1. One migration = one Swift file. No cross-file imports within this folder.
2. Every migration is self-contained: owns its idempotency flag (via Defaults), its `run()` method, its failure handling.
3. Trigger point: `AppState.runPendingMigrations()` called once per app launch from `AppState.init()`.
4. Feature services (AuthService, MoodleService, MoodleTokenService, etc.) MUST NOT reference types declared here.
5. When a migration is no longer needed (all users have been through it), delete the entire file. Do not leave empty shells.
6. File naming: `<Subject><Action>Migration.swift` (e.g., `MoodleTokenMigration`, `LibraryTokenResetMigration`).

## When to add a migration here

- Breaking change in stored data shape (Keychain / UserDefaults / SwiftData / JSON cache)
- One-time bootstrap needed for existing users on app upgrade
- Cleanup of deprecated artifacts left behind by previous versions

## When NOT to use this folder

- Regular feature code — belongs in `Features/` or `Services/<area>/`
- Ongoing runtime policies (retry, refresh) — belongs in the relevant service
- New features — never call anything in this folder from feature code

## Lifecycle

Each migration file lives until all users in production have run it (typically 2–3 release cycles). After that, delete the file and remove its call from `runPendingMigrations()`. The idempotency flag in UserDefaults can be left as-is (harmless orphan) or cleaned up in a subsequent migration.
