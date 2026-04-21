# Widget / LiveActivity Moodle Coupling Audit

**Date:** 2026-04-21  
**Auditor:** T1c task (read-only discovery)

---

## Search Results

### Moodle references in widget/LiveActivity targets

```
rg -c 'Moodle|moodle|moodleToken|MoodleService|MoodleTokenService' swift/TigerDuckLiveActivity/ swift/TigerDuck/LiveActivity/
```

**Results:**
- `swift/TigerDuck/LiveActivity/Resolvers/LiveActivityScenarioResolver.swift`: 1 match

The single match in `LiveActivityScenarioResolver.swift` is **NOT** a Moodle token/auth reference. It is `assignment.moodleDeepLink` — a URL field on `SDAssignment` (a SwiftData model) used to populate `deepLink` in the snapshot. This is a **data field**, not a Keychain/auth access.

```
rg -n 'KeychainKeys\.studentId|KeychainKeys\.password|AppConstants\.KeychainKeys' swift/TigerDuckLiveActivity/
```

**Results:** (no output) — zero Keychain references in the widget extension target.

### Widget extension files

```
swift/TigerDuckLiveActivity/TigerDuckLiveActivityBundle.swift
swift/TigerDuckLiveActivity/TigerDuckLiveActivityLiveActivity.swift
```

---

## Files Examined

| File | Role | Moodle/Keychain access? |
|---|---|---|
| `swift/TigerDuckLiveActivity/TigerDuckLiveActivityBundle.swift` | Widget bundle entry (`@main`) | None |
| `swift/TigerDuckLiveActivity/TigerDuckLiveActivityLiveActivity.swift` | Widget UI (lock screen + Dynamic Island) | None — renders `LiveActivitySnapshot` struct only |
| `swift/TigerDuck/LiveActivity/Resolvers/LiveActivityScenarioResolver.swift` | Scenario selection logic (app-side) | Uses `assignment.moodleDeepLink` (URL field, not auth) |
| `swift/TigerDuck/Services/Auth/SecureStore.swift` | Keychain storage (Valet) | Uses `sharedGroup` (`group.org.ntust.app.TigerDuck`) for studentId/password |
| `swift/TigerDuck/Services/Auth/KeychainManager.swift` | Thin wrapper over SecureStore | Delegates to SecureStore |
| `swift/TigerDuck/Services/Auth/AuthService.swift` | Auth orchestration | Reads/writes `studentId` + `password` via KeychainManager |
| `swift/TigerDuck/App/AppConstants.swift` | Key definitions | `KeychainKeys`: studentId, password, libraryUsername, libraryPassword, libraryToken, libraryTokenExpiry — **no moodleToken key exists** |

---

## Entitlements

**Main app** (`swift/TigerDuck/TigerDuck.entitlements`):
```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.org.ntust.app.TigerDuck</string>
</array>
```

**Widget extension** (`swift/TigerDuckLiveActivityExtension.entitlements`):
```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.org.ntust.app.TigerDuck</string>
</array>
```

Both targets share the same App Group `group.org.ntust.app.TigerDuck`.

---

## Current Keychain Architecture

`SecureStore` uses **two Valet instances**:
1. `shared` — app-only Valet (`Identifier("org.ntust.app.TigerDuck")`)
2. `sharedGroup` — shared group Valet (`SharedGroupIdentifier("group", "org.ntust.app.TigerDuck")`)

`save()` writes to **both** (primary + shared group).  
`load()` reads from `shared` first, falls back to `sharedGroup`, then legacy SecItem.

**Existing keys using shared group:** `studentId`, `password`, `libraryUsername`, `libraryPassword`, `libraryToken`, `libraryTokenExpiry`

**No `moodleToken` key exists** in `AppConstants.KeychainKeys` — it is a planned addition (T4).

---

## Conclusion

**NO_COUPLING**

The widget extension (`TigerDuckLiveActivity`) does **not** access Moodle tokens, Keychain, or any auth service. The widget UI is purely a renderer of `LiveActivitySnapshot` — a pre-computed struct pushed from the app side via ActivityKit's `Activity.update()`. The only Moodle-adjacent reference in the LiveActivity subsystem is `assignment.moodleDeepLink`, which is a URL string field on a SwiftData model, not a credential.

---

## Implication for T4

**moodleToken can use app-only Keychain key (no shared access group needed).**

Rationale:
- The widget extension never reads Keychain directly
- `LiveActivitySnapshot` carries only display data (title, subtitle, countdown, deepLink URL) — no tokens
- The app-side `LiveActivityScenarioResolver` resolves snapshots from SwiftData (`SDAssignment`) which is populated by `MoodleService` (app-only network layer)
- `MoodleService` uses session cookies (not a stored token) for Moodle auth — there is no persistent Moodle token in the current codebase at all

**Recommended key for T4:** Add `static let moodleToken = "moodle_token"` to `AppConstants.KeychainKeys` and store it using the existing `SecureStore.shared` (app-only Valet). No need to write to `sharedGroup`.

However, note that `SecureStore.save()` currently writes to **both** `shared` and `sharedGroup` unconditionally. If T4 wants truly app-only storage, it should call `shared.setObject(...)` directly rather than going through `SecureStore.save()`. Alternatively, accept the current dual-write behavior (harmless for the widget since it never reads Keychain).
