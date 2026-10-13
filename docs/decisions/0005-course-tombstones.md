# 0005. Apply course tombstones before reading a term as empty

Status: accepted

## Context

Courses sync through the backend's `/sync/courses` routes (`server/routes/sync/` in
`tigerduck-app/tigerduck-backend`), and `/sync/full` returns every term's rows (`courses`) and
deletion records (`course_tombstones`). The server keys every row a device uploads
"client:{semester}:{course_no}", enrolled and manual courses alike.
`DELETE /sync/courses/{key}` matches that exact `course_key` and writes a tombstone; the
Moodle idnumber, which `PATCH /sync/courses/{id}/override` takes, deletes nothing. An upload
only upserts, and its `force_keys` re-assert the keys they name past any tombstone. A
semester reset (`AppState.deleteBackendCourses(semester:thenLocally:)`) leaves the server
with no rows for the term and a tombstone for every course it held.

## Decision

- `AppState.reconcileCourses` (`swift/TigerDuck/App/AppState+CourseReconcile.swift`) applies a
  term's tombstones before anything reads the term's emptiness.
- A reset tombstone does not bind the device that wrote it, by the backend's rule: that
  device's next upload releases the tombstones for the keys it names. The reconcile skips a
  tombstone whose `deleted_by_reset` and `deleted_by_this_device` are both true; a
  single-course delete binds its author like every other device.
- A term with no server rows (a first sync, or another device mid-reset) is uploaded from what
  the tombstones leave visible, instead of being read as deleted elsewhere.
- The resetting device keeps the term in `resettingSemesters` across the DELETE and the local
  reset, and stamps the reset once the DELETE lands (`DataCache.recordSemesterReset`), so a
  snapshot fetched before then is never reconciled into the term.

## Alternatives

- Reading the term's emptiness first: the device kept the pre-reset roster and re-uploaded it
  on every refresh, the backend refused that upload without an error, and a reset on one device
  never reached the others.
- Letting reset tombstones bind their author: a poll between the reset's DELETE and the next
  upload would hide every course, and the refetch, which filters by the tombstone store, would
  upload nothing and never release them.

## Consequences

- The tombstone pass must stay ahead of the empty-term branch in `reconcileCourses`.
- Code that builds a course key must use "client:{semester}:{course_no}", as
  `deleteBackendCourse`, the keep-local conflict resolution in `AppState+Conflicts.swift`, the
  hand-add paths (`ClassTableView`, `MacClassTableView+Editing`) and the color overrides in
  `AppServiceBridge.fetchCourses` do.
