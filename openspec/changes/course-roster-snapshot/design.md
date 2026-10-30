# Design

## Context

See proposal.md for the problem. Current state:

- `upload_courses` in `server/routes/sync/uploads.py` upserts each listed course and never
  touches `enrollment_status`; the class reminder scan (`server/push/course_reminders.py`) and
  `server/academic_calendar/changes.py` read only `enrolled` rows, while
  `server/syncjobs/assignments.py` reads every row.
- `/v3/sync/full` already returns `enrollment_status` per course; neither app reads it.
- iOS: the roster fetch in `Bridge/AppServiceBridge.swift` saves the term's courses and uploads
  them (`uploadVisibleCourses`); `term.roster != nil` tells that course selection served the term.
  Uploads are skipped when the request's fingerprint is unchanged (`PushCoordinator.uploadIfChanged`).
- iOS: `App/AppState+CourseReconcile.swift` merges server rows the local roster lacks into the
  hand-added list (`userAdded`). `keptRows` filters only the courses this device saw course
  selection drop (`selectionDropped`), so a device that did not see a drop shows it.
- Uploads that are not rosters exist on both apps: a hand-add sends the added course alone;
  delete and keep-local paths send the device's whole list, merged courses included; Android
  falls back to Moodle enrolments when course selection does not serve the term.
- The backend ignores unknown request fields (Pydantic's default), so a client may send
  `roster_terms` before the backend reads it.

## Goals / Non-Goals

**Goals:**
- Enrollment on the backend follows the school's roster, decided only by uploads that are rosters.
- Every device shows the backend's enrollment, whichever device saw the drop.
- Each piece can ship on its own, in any order, without making things worse.

**Non-Goals:**
- Changing how hides, hand-adds, resets or course content are merged.
- Forcing released apps to update.

## Decisions

### D1. The device says which terms are a roster
An upload carries `roster_terms: [String]`, the terms whose listed courses are the complete
roster. The backend drops only within those terms.
- Lost: treating "absent from an upload" as dropped. Delete-path uploads, hand-adds and Android's
  Moodle fallback all send partial or stale lists, and the backend cannot tell them apart.
- Lost: "absent from an upload by the device that listed the row last" (the held branch). It still
  drops a course a device shows when that device last listed it through a delete-path upload, and
  a drop waits for whichever device listed the course last.
- Lost: a separate roster endpoint. The roster already travels in the upload; one field is less
  code on three clients.

### D2. A drop is a status, not a deleted row
The row stays with `enrollment_status = 'dropped'`.
- Lost: deleting the row. Its colour, custom name and ignore setting would go with it, and a
  student who re-enrolls would lose them; the status is already read by the scan and the snapshot.

### D3. Only a roster or a hand-add changes enrollment
Uploads outside their roster terms keep each existing row's status; a hand-add sets `enrolled`.
- Lost: "every listing re-enrolls". Delete-path uploads and released apps relist merged copies of
  dropped courses, which would undo every drop, the hand corrections of 2026-10-30 included.

### D4. A hand-added course stays off the roster
A school row with a hand-add (`added_at` set) and a `user_added` row are never dropped by a roster.
- Lost: dropping them too. The user put the course on the table on purpose (an audited class, a
  course course selection does not list).

### D5. An empty roster term drops nothing
Both on the device (no roster is sent) and on the backend (a defensive no-op).
- Lost: dropping the whole term. iOS already reads an empty course selection answer as "no
  answer", because the page scrape returns nothing when the page changes; one bad fetch would
  otherwise wipe a student's term.

### D6. Apps read the status instead of guessing
On sync an app skips `dropped` rows when merging, and removes a merged copy whose row turned
`dropped` (a merged copy has a Moodle ID; a course added by hand on this device has none). The
local `selectionDropped` filter stays as a fallback for the case where the backend has not yet
heard a roster.
- Lost: keeping only the local filter. It cannot know about a drop another device saw.

### D7. The roster flag is part of the upload's fingerprint
`roster_terms` is a field of the request, so it changes the fingerprint, and the first fetch after
the app update uploads the term once with the flag even when the courses did not change. That is
how stale rows of students who dropped a course weeks ago get retired.

### D8. iOS first, then the backend, then Android
iOS can ship first: the backend ignores `roster_terms` until it reads it, and the status it reads is
already in the snapshot. The backend change can ship before or after; until then the hand
corrections hold, because today's upsert does not touch the status either.

### D9. The backend asks for a roster instead of fetching one
The backend has no school password, so it cannot read course selection. It records when each
user's roster for a term last arrived (a small table keyed by user and term, written by a roster
upload) and lists the current term in `/v3/sync/full`'s `roster_requests` when that is older than
7 days (a setting). The app answers with a fresh course selection fetch and an upload that skips
the unchanged-fingerprint check.
- Lost: having the app upload a roster on every fetch. The policy would live in two apps instead
  of one place, and every refresh would cost an upload.
- Lost: reading Moodle on the backend. Moodle keeps a dropped class in its course list, so it
  cannot show a drop; sites that are not classes (language tests and the like) would need a
  filter as well.

### D10. Retire released versions with 410 after the fix ships
iOS has shown an "update required" alert on any 410 since 2.0.2 (`APIVersionGate`). Once both
fixed apps are out, the backend answers sync requests from devices below a minimum version
(`user_devices.app_version`) with 410. The minimum and the date are set then, with the owner.
- Lost: retiring now. Students would be asked to update before a fixed version exists.

## Risks / Trade-offs

- [Course selection answers with a partial list] → the device drops a real course until its next
  roster lists it again; course selection is the school's own record, the empty case is excluded,
  and the drop is undone by the next roster.
- [A student uses only a released app] → no roster ever drops their courses; the current term was
  fixed by hand, and the release notes ask everyone to update.
- [A device shows a course it merged earlier, before its first sync after the update] → the merged
  copy is removed on that sync; reminders already stopped on the backend.
- [The roster comes from course selection on one device and Moodle on another (Android)] → only the
  course selection one is flagged, so Moodle never drops anything.

## Migration Plan

1. iOS PR to `dev` (send `roster_terms`, read the status); ships in the next app release.
2. Backend PR to `dev` (D1-D5 and `syncjobs/assignments.py`), released as 3.10.1 and deployed with
   the usual backup, start check and post-check. `MIGRATE.md` notes that no migration runs.
3. Android PR by its maintainer.
- Rollback: the backend change only adds rules; checking out the previous release restores today's
  behaviour, and statuses stay as they are. The ids of the rows corrected by hand are in
  `dropped-courses-1151-20261030.txt` in the production checkout on the server.

## Open Questions

- Whether past terms' stale rows should be retired too, for the course changes query, once a
  device sends a past-term roster (iOS rebuilds past terms from the final transcript, D1). The
  owner agreed to leave them for now.
- The minimum app version and the date for D10.
