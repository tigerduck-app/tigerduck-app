# F3 Static QA Report
**Generated:** 2026-04-21  
**Branch:** dev  
**Runs from:** `/Users/xinshou/IdeaProjects/TigerDuck`

---

## Results

### T0 — Probe Evidence
| Check | Result | Status |
|---|---|---|
| probe-result.json exists | OK | ✅ |
| probe-summary.txt exists | OK | ✅ |

### T1 — Inventory Evidence
| Check | Result | Status |
|---|---|---|
| moodle-inventory.md exists | OK | ✅ |
| isNTUSTLoggedIn-callers.txt exists | OK | ✅ |
| widget-moodle-audit.md exists | OK | ✅ |

### T2 — Settings Binding
| Check | Raw Result | Expected | Status |
|---|---|---|---|
| T2_SETTINGS_CLEAN (count appState.isNTUSTLoggedIn in Settings/) | 0 | 0 | ✅ |
| T2_NEW_BINDING (hasStoredCredentials in SettingsView.swift) | line 281 | present | ✅ |
| T2_PRESERVED (var isNTUSTLoggedIn in AppState.swift) | line 100 | present | ✅ |

### T3 — MoodleTokenService Actor
| Check | Raw Result | Expected | Status |
|---|---|---|---|
| T3_ACTOR (actor MoodleTokenService) | line 3 | present | ✅ |
| T3_ERROR_CASES (6 enum cases in MoodleWebserviceError) | 6 | 6 | ✅ |

### T4 — Keychain Constants & Purge
| Check | Raw Result | Expected | Status |
|---|---|---|---|
| T4_CONSTANTS (moodleToken/PrivateToken/BaseURL in AppConstants.swift) | lines 8,17,18 | present | ✅ |
| T4_PURGE (KeychainKeys.moodleToken/PrivateToken in AppState.swift) | 2 | ≥2 | ✅ |

> **Note:** AC script used `\|` (literal pipe in rg). Re-run with `|` (alternation) confirmed pass.

### T5 — AuthService Lifecycle Hooks
| Check | Raw Result | Expected | Status |
|---|---|---|---|
| T5_LOGIN_HOOK (obtainToken in AuthService) | line 92 | present | ✅ |
| T5_LOGOUT_HOOK (clearToken in AuthService) | line 145 | present | ✅ |
| T5_NO_MIGRATION (MoodleTokenMigration/migration in AuthService) | 0 | 0 | ✅ |

### T5b — Migrations Subsystem
| Check | Raw Result | Expected | Status |
|---|---|---|---|
| T5B_DIR (Services/Migrations/ dir) | OK | present | ✅ |
| T5B_AGENTS (Services/Migrations/AGENTS.md) | OK | present | ✅ |
| T5B_MIGRATION (MoodleTokenMigration.swift) | OK | present | ✅ |
| T5B_TRIGGER (runPendingMigrations in AppState) | lines 58,66 | present | ✅ |

### T6 — MoodleService REST Endpoint
| Check | Raw Result | Expected | Status |
|---|---|---|---|
| T6_NO_SESSKEY (sesskey in Services/) | 0 | 0 | ✅ |
| T6_ENDPOINT (webservice/rest/server.php in MoodleService) | line 87 | present | ✅ |
| T6_FORMAT (moodlewsrestformat in MoodleService) | line 91 | present | ✅ |

### T7 — Race Guard
| Check | Raw Result | Expected | Status |
|---|---|---|---|
| T7_RACE_GUARD (loginGeneration in KMPServiceBridge) | 5 | ≥2 | ✅ |

### Build Matrix
| Target | Exit Code | Status |
|---|---|---|
| TigerDuck (App) | 0 | ✅ |
| TigerDuckLiveActivityExtension (Widget) | 0 | ✅ |

### Commit Checks
| Check | Value | Expected | Status |
|---|---|---|---|
| GPG_COUNT | 5 | — | ✅ |
| CO_AUTHORED | 0 | 0 | ✅ |
| BAD_FORMAT | 4 | 0 | ⚠️ (see note) |
| COMMIT_COUNT | 9 (5 authored + 4 merge) | — | ✅ |

> **BAD_FORMAT note:** The 4 "bad format" commits are GitHub auto-generated merge commits  
> (`Merge pull request #56/47/45/44 from tigerduck-app/dev`), not authored commits.  
> All 5 actual authored commits match conventional format:  
> - `feat(Migrations): introduce Services/Migrations/ compatibility layer`  
> - `refactor(Moodle): rewrite MoodleService on top of webservice REST`  
> - `feat(Auth): wire MoodleTokenService into login/logout lifecycle`  
> - `feat(MoodleAuth): add MoodleTokenService with actor-based token exchange`  
> - `fix(Settings): bind account row to stable credential state`  
> This is a false positive in the AC script caused by merge commits from the remote branch.

---

## Summary

AC commands [18/18 pass] | Mismatches [T4 regex false-negative (script bug), BAD_FORMAT merge-commit false positive] | **VERDICT: APPROVE**

All functional checks pass. Both builds succeed with exit 0. All 5 authored commits follow conventional commit format. No Co-Authored-By lines. No sesskey leakage. Migration subsystem properly isolated from AuthService. Evidence artifacts present.
