# Tasks

## 1. iOS PR: report rosters and read enrollment

- [x] 1.1 Add `rosterTerms` (`roster_terms`) to `PushAPI.CourseUploadRequest` and verify a unit test encodes it and that the upload fingerprint changes with it
- [ ] 1.2 Send the term in `roster_terms` from the roster fetch only when course selection served it (`term.roster != nil`) or a past term was rebuilt from the final transcript, never for an empty list; verify with tests for each source (selection, cache, transcript, empty)
- [ ] 1.3 In the course reconcile, skip server rows whose `enrollment_status` is `dropped` when merging, and remove a merged copy (one with a Moodle ID) whose row is `dropped`, keeping courses added by hand on this device; verify with reconcile tests that fail on `dev`
- [ ] 1.4 Verify Live Activity filing, widgets and the Watch payload read the merged class table, so a dropped course leaves them too; add a test if any reads the server rows directly
- [ ] 1.5 Read `roster_requests` from `/v3/sync/full`; for a requested term run a fresh course selection fetch and upload the roster with `roster_terms` past the unchanged-fingerprint check, sending nothing when course selection does not answer; verify with tests for both cases
- [ ] 1.6 Run the touched suites and the whole phone target on xs-mac, the macOS build, `check_comments.py` and `check_macos_sources.py`

## 2. Backend PR: enrollment from rosters (3.10.1)

- [ ] 2.1 Accept `roster_terms` on `POST /v3/sync/courses/upload` and, per roster term, set listed school courses to `enrolled` and unlisted ones without a hand-add to `dropped`; verify with tests that fail on `dev`
- [ ] 2.2 Keep existing rows' status on uploads outside their roster terms and set `enrolled` on a hand-add (`adds`, `force_keys`); verify with tests for a stale relist and a hand-add of a dropped course
- [ ] 2.3 Make an empty roster term a no-op; verify with a test
- [ ] 2.4 Read only enrolled courses in `server/syncjobs/assignments.py`; verify with a test
- [ ] 2.5 Record when each user's roster for a term arrives (new table and Alembic migration) and list the current term in `/v3/sync/full`'s `roster_requests` when that is older than a setting defaulting to 7 days; verify with tests for a missing, an old and a recent roster
- [ ] 2.6 Add the 3.10.1 `MIGRATE.md` section (the migration, the rule, the hand correction) and the rule in `server/AGENTS.md`; verify the touched files and the full server suite pass on xs-mac

## 3. Backend release and deploy

- [ ] 3.1 Bump to 3.10.1, open the release PR, deploy with backup, start check and post-check; verify the post-check passes and the class reminder scan files nothing for `dropped` rows

## 4. iOS release

- [ ] 4.1 Ship group 1 in the next app release; verify after a week that production has no `enrolled` current-term row missing from its student's newest roster upload that carries `roster_terms`

## 5. Android (its maintainer)

- [ ] 5.1 Send `roster_terms` only when course selection served the term (never from the Moodle fallback), answer `roster_requests`, read `enrollment_status` when merging server rows, and remove merged dropped copies; verify with its tests

## 6. Retire released versions (after groups 4 and 5 ship)

- [ ] 6.1 With the owner, set the minimum app version and date; answer sync requests from devices below it with 410; verify an old-version request gets 410 and iOS 2.0.2+ shows the update alert

## Workflow follow-up

- Archive the change after the last pull request merges: `openspec archive course-roster-snapshot`.
