# Tasks

## 1. iOS PR: report rosters and read enrollment

- [ ] 1.1 Add `rosterTerms` (`roster_terms`) to `PushAPI.CourseUploadRequest` and verify a unit test encodes it and that the upload fingerprint changes with it
- [ ] 1.2 Send the term in `roster_terms` from the roster fetch only when course selection served it (`term.roster != nil`) or a past term was rebuilt from the final transcript, never for an empty list; verify with tests for each source (selection, cache, transcript, empty)
- [ ] 1.3 In the course reconcile, skip server rows whose `enrollment_status` is `dropped` when merging, and remove a merged copy (one with a Moodle ID) whose row is `dropped`, keeping courses added by hand on this device; verify with reconcile tests that fail on `dev`
- [ ] 1.4 Verify Live Activity filing, widgets and the Watch payload read the merged class table, so a dropped course leaves them too; add a test if any reads the server rows directly
- [ ] 1.5 Run the touched suites and the whole phone target on xs-mac, the macOS build, `check_comments.py` and `check_macos_sources.py`

## 2. Backend PR: enrollment from rosters (3.10.1)

- [ ] 2.1 Accept `roster_terms` on `POST /v3/sync/courses/upload` and, per roster term, set listed school courses to `enrolled` and unlisted ones without a hand-add to `dropped`; verify with tests that fail on `dev`
- [ ] 2.2 Keep existing rows' status on uploads outside their roster terms and set `enrolled` on a hand-add (`adds`, `force_keys`); verify with tests for a stale relist and a hand-add of a dropped course
- [ ] 2.3 Make an empty roster term a no-op; verify with a test
- [ ] 2.4 Read only enrolled courses in `server/syncjobs/assignments.py`; verify with a test
- [ ] 2.5 Add the 3.10.1 `MIGRATE.md` section (no migration, the rule, the hand correction) and the rule in `server/AGENTS.md`; verify the touched files and the full server suite pass on xs-mac

## 3. Backend release and deploy

- [ ] 3.1 Bump to 3.10.1, open the release PR, deploy with backup, start check and post-check; verify the post-check passes and the class reminder scan files nothing for `dropped` rows

## 4. iOS release

- [ ] 4.1 Ship group 1 in the next app release; verify after a week that production has no `enrolled` current-term row missing from its student's newest roster upload that carries `roster_terms`

## 5. Android (its maintainer)

- [ ] 5.1 Send `roster_terms` only when course selection served the term (never from the Moodle fallback), read `enrollment_status` when merging server rows, and remove merged dropped copies; verify with its tests

## Workflow follow-up

- Archive the change after the last pull request merges: `openspec archive course-roster-snapshot`.
