# Issues — auth-persistence-fix

## [2026-04-20] Known Risks
- T0 probe may fail if Moodle endpoint is Shibboleth-protected → plan halts
- T3 and T4 have a soft dependency (T3 needs key names from T4, but can use local const temporarily)
- T6 may need to create MoodleWebserviceModels.swift if existing models don't match REST response format
- Widget Moodle coupling (T1c) determines whether moodleToken needs shared Keychain access group

## T5b Build blocker (2026-04-21)
- `xcodebuild build` did not reach migration verification because the target currently fails in `Bridge/KMPServiceBridge.swift:155` with `cannot find 'MoodleService' in scope`.
- Build log captured at `.sisyphus/evidence/task-5b-xcbuild.log`. This blocker appears outside the files changed for T5b, so C3b was not created.
