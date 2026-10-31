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
  tombstone whose `deleted_by_reset` and `deleted_by_this_device` are both true.
- A single-course delete of a course the school lists for the term binds its author like every
  other device: the author hides it locally, and its roster uploads leave it out.
- A single-course delete of a hand-added course does not bind its author. From backend 3.3.6
  the server records the tombstone as `user_added`, leaves it out of the author's `/sync/full`,
  and releases it on the author's next upload without `force_keys` that lists the course.
  The author removes the course without a local hide (`CourseFiles.deleteCourse`), so once
  course selection lists it the class table shows it and the roster upload names it. Every
  other device stays bound until then. Only a course added by hand on this device, which has
  no Moodle ID, counts: one merged from another device's row carries a Moodle ID and is hidden,
  since the server may not have recorded it as `user_added`.
- A term with no server rows (a first sync, or another device mid-reset) is uploaded from what
  the tombstones leave visible, instead of being read as deleted elsewhere.
- The resetting device keeps the term in `resettingSemesters` across the DELETE and the local
  reset, and stamps the reset once the DELETE lands (`CourseFiles.recordSemesterReset`), so a
  snapshot fetched before then is never reconciled into the term.

## Alternatives

- Reading the term's emptiness first: the device kept the pre-reset roster and re-uploaded it
  on every refresh, the backend refused that upload without an error, and a reset on one device
  never reached the others.
- Letting reset tombstones bind their author: a poll between the reset's DELETE and the next
  upload would hide every course, and the refetch, which filters by the tombstone store, would
  upload nothing and never release them.
- Hiding a deleted hand-added course and lifting the hide once course selection lists it: the
  same outcome with one more stored list, and a list lifted on the disk alone leaves the class
  table's copy of the hides stale.

## Consequences

- The tombstone pass must stay ahead of the empty-term branch in `reconcileCourses`.
- Code that builds a course key uses `CourseTombstone.serverKey(semester:courseNo:)`, which
  gives "client:{semester}:{course_no}", as the course upload (`AppState.courseUploadRequest`),
  the outbox's course deletes, Use Local's deletes (`AppState.keepLocalCourses`) and the hand-add
  paths' forced keys (`ClassTableView`, `MacClassTableView+Editing`) do; adding a course back
  drops its queued delete by that key (`CloudSyncCoordinator.discardCourseDeletes`).
- A course deleted here is deleted on the server through the outbox, which retries until the
  delete lands. Until then the server still lists it, and the reconcile keeps it hidden here for
  as long as its delete is queued (`CloudSyncCoordinator.pendingCourseDeleteKeys`). A hand-added
  course whose delete the outbox gives up on comes back, as nothing hides it.
- The outbox sends a course delete with the time the hide was made (`hlc`), and a course add as
  a protocol-2 upload of that course alone with its time in `adds`. The backend applies either
  only when that time is later than the course's last add, hide and reset, so an edit that waited
  in the outbox, or a retry after a lost reply, does not undo a newer one from another device
  (tigerduck-app/tigerduck-app#689). One the backend refuses as ahead of its clock goes again
  without its time and counts from when it arrives.
- A hand-added course deleted before this rule keeps its local hide, since nothing recorded
  which hides came from one.
