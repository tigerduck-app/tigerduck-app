# Decisions — auth-persistence-fix

## [2026-04-20] Architecture Decisions
- MoodleTokenService: Swift actor (NOT class), NO protocol abstractions
- Token storage: KeychainManager (NOT UserDefaults)
- Migration code: ONLY in Services/Migrations/ folder
- Moodle token failure in login(): non-fatal, log only, never cascade to NTUST login state
- logout(): fire-and-forget clearToken() via Task { } to avoid blocking UI
- refreshTokenIfNeeded(): reads Keychain credentials, NO UI, NO SSO re-flow
