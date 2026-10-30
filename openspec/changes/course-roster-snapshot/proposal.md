# Proposal

## Why

A school course that leaves a student's roster (dropped during add/drop, or withdrawn later)
keeps its backend row as `enrolled` for good, because `POST /v3/sync/courses/upload` only
upserts what it is sent and no upload says whether it is the whole roster. Each app hides the
row only when it saw the drop itself; a device that did not see it merges the row into its class
table, files Live Activities for it and can upload it again. Since the backend's class reminders
started working on 2026-10-29, students have been getting reminders for courses they dropped.

## What Changes

- A course upload carries `roster_terms`, the terms whose courses in that upload are the
  school's complete roster. An app sends a term there only when course selection served that
  term, or, on iOS, when a past term is rebuilt from the final transcript. Lists built from the
  cache, a running term's transcript or Moodle are never sent as a roster.
- For a roster term the backend sets every listed school course to `enrolled`, and every school
  course it does not list, unless the user added it by hand, to `dropped`. A roster term that
  lists no course changes nothing.
- An upload without `roster_terms` no longer changes an existing row's `enrollment_status`, so
  a stale list from another path or an older app cannot bring a dropped course back. A hand-add
  sets the course to `enrolled`.
- Both apps read `enrollment_status` from `/v3/sync/full` and treat a dropped course as absent:
  it is not merged into the class table, a copy merged earlier is removed, and nothing (Live
  Activities, class reminders, widgets) is built from it.
- Backend jobs that build a class table from `user_courses` read enrolled courses only.
- Production's current-term rows were corrected by hand on 2026-10-30, so no data migration.

This reverses one out-of-scope line of `tigersync-last-writer-wins` ("Removing school rows that a
newer roster no longer lists"). The hide, add and reset rules of that change are unchanged.

## Capabilities

### New Capabilities
- `course-roster`: which school courses a student is enrolled in per term, how a device reports
  the roster to the backend, and how every device and backend job reads enrollment.

### Modified Capabilities

None.

## Out of scope

- Released app versions: they send no `roster_terms`, so their uploads drop nothing, and they
  keep showing a merged dropped course until they update.
- Delete-path uploads that send the device's whole list: they stay as they are. With the rule
  above they no longer affect enrollment.
- Past terms' stale rows: the backend sends no reminders for past terms, so they are left.
- Telling the students who got wrong reminders.
- Course content (name, room, schedule) and user edits (hide, add, colour, name), which keep the
  rules of `tigersync-last-writer-wins`.

## Impact

- Backend (`tigerduck-backend`): `server/routes/sync/uploads.py`, `server/syncjobs/assignments.py`,
  tests under `server/tests/`, `MIGRATE.md`, `server/AGENTS.md`. The held branch
  `fix/retire-dropped-roster-courses` is reworked to this rule.
- iOS: `Services/Push/PushAPIDTO.swift` (`CourseUploadRequest`), `Bridge/AppServiceBridge.swift`
  (the roster fetch and its upload), `App/AppState+BackendSync.swift` (`uploadCourses`),
  `App/AppState+CourseReconcile.swift` (the merge of server rows), tests in `swift/TigerDuckTests/`.
- Android (`tigerduck-app-android`): its fetch upload, its server-row merge and its add path; its
  maintainer implements them.
