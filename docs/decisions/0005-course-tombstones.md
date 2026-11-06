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
semester reset (`EditSender.deleteBackendCourses(semester:thenLocally:)`) leaves the server
with no rows for the term and a tombstone for every course it held.

## Decision

- `CourseRosterReconciler.reconcileCourses`
  (`swift/TigerDuck/Backend/Sync/Reconcilers/CourseRosterReconciler.swift`) applies a term's
  tombstones before anything reads the term's emptiness.
- A reset tombstone does not bind the device that wrote it, by the backend's rule: the next
  roster upload lifts the reset tombstones of the keys it names. `/v4` names no device on a
  tombstone, so the reconcile skips one of kind `reset` whose `hlc`, the reset's stamp, is at or
  before the moment this device's own reset of the term landed
  (`CourseRosterReconciler.isOwnReset`), and keeps that moment while the snapshot still shows
  such a tombstone.
- A single-course delete of a course the school lists for the term binds its author like every
  other device: the author hides it locally, its roster uploads leave it out, and the outbox
  sends the delete with `kind=hide`, so the backend hides it even when another device's add has
  just made its row `user_added`.
- A single-course delete of a course added by hand on this device, which has no Moodle ID, is a
  removal: the author drops it without a local hide (`CourseFiles.deleteCourse`), and the outbox
  sends the delete of a course this device does not hide with `kind=remove`. The backend then
  writes a `remove` tombstone, even for a course whose add never reached it, and keeps a school
  row of the key. `/v4` gives every device every tombstone with its `kind`. The reconcile hides a
  course only for a `hide` tombstone or another device's `reset`; a `remove` tombstone takes the
  term's hand-added and merged copies of the course with no hide, and leaves a course the school
  lists here. So once course selection lists the course, every device shows it and the roster
  upload names it. A course merged from another device's row carries a Moodle ID and is hidden
  when deleted here; its delete goes with no kind, which the backend takes as a removal of a
  `user_added` row and a hide of any other.
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
  gives "client:{semester}:{course_no}", as the course upload (`SchoolDataUploader.courseUploadRequest`),
  the outbox's course deletes, Use Local's deletes (`SyncConflicts.keepLocalCourses`) and the hand-add
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
  stamped one tick after the backend's clock. A delete reads its kind from this device's hides
  as it goes, so it waits while protected data is locked, and it is dropped unsent once course
  uploads are off, as an add is.
- The backend takes every course an upload lists outside `adds` for the school's, and turns a
  `user_added` row it lists into a school row, which a delete with no kind then hides everywhere
  and a roster drops once a reset has cleared its add. So only the add's own upload and Use
  Local's list a course added by hand. Use Local names in `adds` each course added by hand on
  this device (no Moodle ID, and not listed by the school here), stamped after its term's reset,
  and sends a merged copy as the school's. A class table delete sends its delete alone.
- Use Local's term resets clear the backend's custom names, so Use Local sends the names, and
  the colours, of every course this device holds again, hidden ones included. The backend holds
  no row of a hidden course, so such an edit waits in the outbox until a course upload brings
  the row back.
- A hand-added course deleted before this rule keeps its local hide, since nothing recorded
  which hides came from one, and so does a course a `remove` tombstone hid before the reconcile
  told the kinds apart, until the snapshot lists the course again with no delete of it queued
  here (`CourseRosterReconciler.unhideListedCourses`).
