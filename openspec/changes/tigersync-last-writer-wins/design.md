# Design

Backend paths are in `tigerduck-app/tigerduck-backend` at `origin/dev` (3.6.0), Android paths in
`tigerduck-app/tigerduck-app-android` at `origin/main` (2.3.1); the rest are in this repository.

## Context

See proposal.md for why. What shapes the approach:

- Besides settings documents, the apps write through four route groups only: `PATCH /v3/sync/{assignments,courses}/{id}/override`
  (`server/routes/overrides.py`), `POST /v3/sync/courses/upload` and `/assignments/upload`,
  `DELETE /v3/sync/courses[/{key}]` (`server/routes/sync/`), and
  `PUT /v3/sync/holiday-overrides/{id}`. They read `/v3/sync/full`, `/v3/sync` and
  `/v3/sync/revision`. `PUT /v3/{courses,assignments}/{id}/override` (`server/routes/academics.py`)
  and `POST /v3/sync/initial-upload` already merge per field with client times
  (`server/sync/merge.py`), but neither app calls them.
- The override PATCH routes stamp every edit with server `now`, so arrival order decides. The
  read-compare-write in `apply_field` takes no lock.
- The released apps send no edit time, and the backend must keep serving them while iOS and
  then Android ship.
- iOS already timestamps every outbox entry (`SyncOp.stamp` in
  `swift/TigerDuck/Services/CloudSync/SyncOutbox.swift`) but drops the stamp in `resolve`.
  Android keeps in-flight ids in memory only (`HomeSyncState.pendingOverrides` in
  `ui/screen/home/HomeBackendSync.kt`).
- The device keeps marks, ignores, hides and hand-adds as plain sets
  (`swift/TigerDuck/Services/Core/DataCache.swift`), with no time per entry.

## Goals / Non-Goals

**Goals:**
- One comparison rule, run on the backend, that every client trusts; clients hold their unsent
  edits and otherwise take what the backend returns.
- Delete the iOS heuristics that guess at order, listed under D12.
- A backend that serves released apps unchanged while new ones adopt the clock.

**Non-Goals:**
- A generic CRDT or vector clocks: one user edits on a few devices, and the owner chose
  last-writer-wins.
- Changing what a field means, or which fields sync.

## 1. Inventory

What TigerSync syncs today, how it resolves, and how it will. "Arrival" means the backend
stamps the request with its own time when it lands.

| Item and field | Backend storage | Device storage (iOS) | Resolves today | Resolves after |
|---|---|---|---|---|
| Assignment mark (`local_status`), per assignment | `user_assignment_overrides.local_status`, `local_status_updated_at` | `archived_assignments.json`, `locally_completed_assignments.json` | Arrival on the PATCH; a clear deletes the row. iOS keeps in-flight ids (`pendingOverrides`, outbox), shows the per-assignment conflict alert (`syncConflicts`) when both sides hold different marks, and uploads local marks at first sync only if the server has none (`uploadsLocalMarksAsFirstSync`) | Clock, per assignment; a clear is a stamped `none` row |
| Assignment note | `note`, `note_updated_at` | none | Client time on routes no app calls | Unchanged for the apps; the shared merge applies |
| Course colour | `user_course_overrides.color_hex`, `color_hex_updated_at` | `course_color_map.json`, `picked_course_colors.json` | Arrival on the PATCH; a roster upload's colours fill a course with none. iOS holds colours queued or edited since the fetch (`courseOverridesToHold`) | Clock; roster colours stay fill-only (oldest) |
| Course name, per locale | `custom_names` (JSONB), one `custom_name_updated_at` for the map | `course_custom_names.json` | Arrival; one stamp covers both locales. iOS holds names as for colours | Clock, per locale (`custom_names_updated_at` JSONB) |
| Ignore a course's assignments | `ignore_assignments`, `ignore_assignments_updated_at` | `ignored_courses.json` | Arrival. iOS merges through `mergedIgnoredCourses`, `serverDecidedCourses`, `recreatedCourses` (row ids, `courseRowIdsSeen`) and re-sends settings "the server lost" (`resend`) | Clock |
| Course's numeric Moodle id | `moodle_course_id` on the override | lookup | Latest request, routing data for the reminder scan | Unchanged, not stamped: not a user choice |
| Course membership, per course key | `user_courses` rows (`source`), `user_course_tombstones` (`deleted_at`, `deleted_by_reset`, `user_added`), `users.courses_reset_at` | `deleted_courses.json` (hides), `user_added_courses.json`, outbox `courseDelete` / `courseAdd` | A tombstone blocks uploads unless `force_keys` names the key; a reset's tombstones release for their author's next upload; a hand-added course's tombstone releases for its author's roster. Snapshot sends 30 days of tombstones. iOS adds a delete grace (`recentCourseDeletions`), `resettingSemesters`, `semesterResetAt`, `unlistedCourses`, `courseAddKeys(unlandedAt:)` and, on #689's branch, cutoffs comparing device time with server `deleted_at` | Clock: add, hide, removal and term reset are stamped; a roster upload never overrides them (D10) |
| Holiday "notify anyway" | `user_holiday_overrides.notify`, `updated_at` | `AcademicCalendarStore` opt-ins | Arrival | Clock, stored in `updated_at` |
| Settings documents | `user_settings_documents` with `revision` | per namespace | Revision compare-and-swap, JSON merge on 409 (ADR 0002) | Unchanged (out of scope) |
| School data: course rows' school fields, `user_assignments` | same tables, server fetch (`server/syncjobs/`) and uploads | course and assignment caches | Latest upload or fetch | Unchanged; the base layer under every row above |

Skipped class dates stay on each device on both apps; the backend's skipped-date routes are not
called. Bulletin state is per device and not part of TigerSync.

## 2. Decisions

### D1. The clock is one integer of microseconds

A value is `int64` microseconds since the Unix epoch; a device stamps an edit with
`max(device now, last server value seen, last value issued) + 1`, which is the owner's rule plus
the last issued value so a device never repeats a value.

The backend refuses a stamp more than five seconds ahead of its time (D5), so a device caps
`device now` at its estimate of the backend's time plus five seconds: the last `X-TigerSync-Clock`
it heard plus the device time elapsed since. An edit stamped before the device first heard the
backend can still be refused; the refusal carries the backend's clock, and the device lowers its
last issued value to the cap and re-stamps the edit by the same rule. Lowering it is safe: every
stamp the backend stored is at most its time plus five seconds, and the last seen value already
covers those the device has read.

Lost:
- ISO-8601 strings, as the snapshot uses today: Apple's `ISO8601DateFormatter` keeps three
  fractional digits, so two edits within a millisecond would collide and a value Python returns
  with six digits would not round-trip.
- A classic HLC pair (wall time, counter): two wire fields and two columns per field, for an
  edit rate where the counter never matters; folding the counter into the microseconds is what
  the owner's "+1 tick" does.
- Backend-assigned times: today's arrival order, which lets a late offline edit win.

### D2. Stamps live in the timestamp columns that exist

`timestamptz` holds microseconds exactly, so the backend converts at the edge and stores each
stamp in `color_hex_updated_at`, `custom_name_updated_at`, `ignore_assignments_updated_at`,
`local_status_updated_at`, `note_updated_at`, `user_course_tombstones.deleted_at`,
`user_holiday_overrides.updated_at` and `users.courses_reset_at`. New: `custom_names_updated_at`
(JSONB, locale to stamp), `user_courses.added_at`, and `user_semester_resets (user_id, semester,
reset_at)`.

Lost:
- A `bigint *_hlc` column beside every field: twice the columns, every table migrated, and two
  times per field that can disagree.
- One JSONB stamp map per row: `apply_field` and every SQL filter would parse JSON.

### D3. Where each side keeps its clock

iOS keeps the last issued and last seen values, and the last `X-TigerSync-Clock` heard with the
device time it arrived (for D1's cap), in `Defaults` keys behind a small
`SyncClock` in `Services/CloudSync/`. Stamping happens on a user edit, so the phone is unlocked.
`PushAPIClient.execute` raises the last seen value from `X-TigerSync-Clock` only while protected
data is readable, as `syncOverridesFromBackend` already checks, so a background launch before
first unlock cannot write over the stored values. The outbox keeps `SyncOp.stamp` as a `Date`
holding the clock value; sending rounds it to whole microseconds (a `Date` resolves about 0.1
microsecond today). Entries queued before the update keep their queue time, with no change to
the stored shape and so no migration. The backend keeps no clock state: its value is its time.

Lost: a separate stamp store for every local value. The outbox already holds one entry per
field (`dedupKey`) for every unsent edit, which is all a client must remember (D12).

### D4. Clients learn server time from every response

A middleware in `server/main.py` sets `X-TigerSync-Clock` on every `/v3` response, errors too.
Clients also raise the last seen value to every stamp they read in a snapshot or write response,
which covers values stored up to five seconds ahead.

Lost:
- A clock endpoint: one more request, and already stale when an offline edit happens.
- Snapshot stamps alone: an account with no stamped field yet would never learn server time.

### D5. Skew allowance of five seconds; later stamps are refused

The backend accepts a stamp up to five seconds after its own time (a module constant in
`server/sync/merge.py`) and refuses a later one with `409 clock_ahead`, writing nothing. Five
seconds absorbs ordinary NTP drift, so an honest device is never refused. The backend stores only
the value a device sent, so a retry after a lost response carries the stored stamp and changes
nothing (D7). Released apps send no stamp and are never refused (D8).

Lost:
- Clamping to `min(value, now + 5 s)`: each send of the same edit would be clamped again, later
  each time, so a retry after a lost response could beat an edit made meanwhile.
- Zero skew, as `clamp_ts` does today (the owner asked for a small allowance), and a config
  setting (no operator would tune it).

### D6. Atomicity through the per-user sync lock

Every LWW writer calls `lock_sync_state` (`server/sync/changelog.py`) before it reads the stored
stamp. That `FOR UPDATE` row lock is the one every change log append takes, so a user's writes
already serialize at the append; taking it first makes compare and write one step.

Lost:
- `SELECT ... FOR UPDATE` on the override row: a missing row cannot be locked, so two first
  edits race the unique constraint, and membership spans `user_courses` and the tombstones.
- A conditional `UPDATE ... SET f = CASE WHEN ...` per field: per-field SQL, harder to return
  the winner and to decide whether to log a change, and it still needs insert-or-lock.
- `SERIALIZABLE` isolation: retry handling in every route.

### D7. Ties keep the stored value; same content raises the stamp

`apply_field` keeps the stored value on equal stamps, as it does now, so a replay changes
nothing. When the value equals the stored one, a later stamp replaces the stored stamp without
a change log entry or sync push.

Lost:
- Treating same content as a no-op: a course red at 10:00, red again at 10:05 from another
  device, then blue stamped 10:03 would turn blue, against the user's last word.
- Treating it as a change: a change log entry and a push for nothing visible.

### D8. Released apps: stamped at arrival, bulk uploads oldest (recommended policy)

New clients send `X-TigerSync-Protocol: 2` on every request. A stamp in a request is used
whenever present, so iOS can send stamps before it switches protocol. Without the header the
backend serves today's behavior: a single edit without a stamp (override PATCH, course DELETE,
holiday PUT) gets the arrival time and then goes through the same comparison; values inside a
bulk upload (roster colours, `initial-upload` without times) count as oldest; the snapshot keeps
the 30-day tombstone window and today's course upload and delete rules apply.

Trade-off: an old app's late retry wins over a newer edit made on a new app. The window is how
long an old app holds an unsent edit: Android until its process dies, iOS up to five attempts,
then parked marks retried later. That is today's behavior for every client, and it ends as the
apps update.

Lost:
- Legacy edits as oldest: a user on an old app could no longer change a field any new app had
  touched; the tap would revert at the next sync, longest for F-Droid users.
- Refusing legacy writes with 410: forces an update before Android ships, and
  `APIVersionGate` latches the app for good.
- Gating on `user_devices.app_version`: one more lookup per request, and the version only
  updates on registration.
- Detecting protocol 2 from body fields alone: a `GET /v3/sync/full` has no body, and its shape
  differs (all tombstones, kinds, resets).

### D9. A cleared mark is a stamped `none`

`PATCH .../override` with `none` updates every row of the assignment to `none` with the stamp
instead of deleting rows without a note. Released apps already skip `none` in a snapshot.

Lost: deleting the row, which forgets the clear, so an older mark arriving later wins.

### D10. Course membership is a stamped user layer over the roster

Per course key the user's last choice is one of: added (`user_courses` row with `added_at`),
hidden (tombstone, `user_added = false`), removed (tombstone, `user_added = true`), or none.
A term reset is `user_semester_resets.reset_at`; a full reset `users.courses_reset_at`. With
protocol 2:

- An add wins when later than the key's `added_at`, its tombstone and every reset covering it:
  it deletes the tombstone and upserts the row with `added_at` set to its stamp. An add that
  loses changes nothing, so `added_at` never moves back.
- A hide or removal wins when later than `added_at`, the tombstone and the resets, and upserts
  the tombstone. A hide deletes the row (with its overrides, as today), and so does a removal of
  a hand-added row. A removal of a school row (`source` other than `user_added`) only clears its
  `added_at`, so the course shows from the roster whichever of the two arrives first. A
  tombstone is written even when no row exists, so a hide of a course never uploaded still binds.
- A reset wins when later than the term's `reset_at` (a full reset: `courses_reset_at`), and
  records its stamp there; an older reset changes nothing, so a marker never moves back. It
  clears only what is stamped at or before it. Such tombstones go. A hand-added row goes unless
  its `added_at` is later: a newer colour or name does not keep a course whose add the reset
  clears. A school row goes unless its `added_at` or one of its override stamps is later. A row
  that goes leaves today's per-course reset tombstone (`deleted_by_reset`) so released apps
  still obey it. A row that stays loses the
  fields stamped at or before the reset; each returns to its empty value stamped at the reset,
  so an older write (an academics PUT, a first upload, a roster colour) cannot bring it back.
  Afterwards every membership or override edit for that term stamped at or before `reset_at` is
  refused.
- A roster upload upserts school rows, skips keys with a hide tombstone, and deletes reset
  tombstones for the keys it lists. It keeps a removal tombstone beside the school row: a
  removal takes back a hand-add and never hides the school's course, and its stamp still
  refuses older membership edits. It never touches `added_at`, and it turns a hand-added row it
  lists into a school row, so the `courses` of a protocol-2 upload hold only the school's
  roster and a hand-added course goes in `adds`.

Requests without the protocol header keep today's code path: `force_keys`, the author releases
by `deleted_by_device_id`, and `device_id_required`.

Lost:
- A separate membership table with one register per key: cleaner, but every reader of
  `user_courses` (class reminders, Live Activities, `push/presend.py`) would join it. Keeping
  "row means shown, tombstone means not" leaves them unchanged.
- Per-course reset tombstones as the only reset record (today): releasing them needs
  `deleted_by_this_device`, the device-identity rule this change removes, and they cannot refuse
  a stale hand-add from another device.
- Rows absent from a newer roster removed by the roster upload: a school-freshness change,
  out of scope.
- A reset that deletes every row and tombstone of the term regardless of stamps: a reset that
  arrives late would erase adds, hides and colours made after it.
- Deleting a removal tombstone when the roster lists its key: the removal's stamp is lost, and a
  hide stamped before the removal but arriving after the roster would hide the course.

### D11. Tombstones are kept

Which entities have one: course membership (hide, removal, term and full reset, D10); an
assignment mark's clear (D9); a cleared course name, already stored as `""` with its stamp; a
holiday turned off, already stored as `notify = false` with its stamp. A course colour has no
clear: the PATCH reads a null colour as no change. A re-add after a delete is D10's add rule: the later stamp wins.

Retention: the snapshot for protocol 2 returns every tombstone and reset; the 30-day filter in
`_read_full_snapshot` stays for released apps, which also do not get a removal tombstone whose
key has a row, since they hide every tombstone they read. Tombstones still go when every device turns
course sync off (`server/routes/user_devices.py`) and with a full reset, as today; the rows of
D9 and the names and holidays above stay as long as their parent row.

Lost:
- 30 days: an outbox or a device offline longer brings a course back; that gap is why iOS has
  `unlistedCourses`.
- Expiry per term: needs the term calendar in the sync code for a table of a few rows per
  hidden course.

### D12. Clients hold unsent edits and otherwise take the backend's value

On a snapshot, a client keeps its value for a field when the outbox holds an edit for it, or
when the snapshot may predate the client's last acknowledged write to that field: its
`server_hlc` is not later than that write response's `X-TigerSync-Clock` (an in-memory map on
`CloudSyncCoordinator`; a relaunch fetches a snapshot taken after every acknowledged write).
Every other field, and its absence, comes from the snapshot, so a colour a hide or reset took
away goes too. This works because the backend reads `server_hlc` before the snapshot's first
query and sets the header after a write commits: a snapshot with a later `server_hlc` includes
the write. A write response's winner is applied to a field unless the outbox holds an edit for
it made after the one the response answers.

The outbox keeps entries while TigerSync or their category is off (held, as marks already are),
`performDisable` stops clearing it, and sign-out still does (`settleForSignOut`).

This replaces on iOS: `mergedMarks`, `mergedIgnoredCourses`, `ignoredCoursesAfterPull` and its
`resend`, `serverDecidedCourses`, `recreatedCourses` and `courseRowIdsSeen`, `courseKeysPullLeaves`,
`courseOverridesToHold` with `lastColorEdit` / `lastNameEdit`, `pendingOverrides`,
`overrideEditGeneration` and `reasonToLeaveMarks(.editedDuringFetch)`, `recentCourseDeletions`
and its grace, `resettingSemesters`, `semesterResetAt`, `unlistedCourses`, `courseAddKeys`,
`courseDeletes(around:)`, and the cutoffs on `fix/course-outbox-ordering`.

Lost:
- Comparing the acknowledged stamp with the field's stamp in the snapshot: a field the snapshot
  no longer has (hidden course, reset) has no stamp to compare, so the client either keeps a
  removed value for good or loses the protection against a snapshot read before the write.
- Clients comparing their own stamps with the backend's: every local value would need a stored
  stamp, and two arbiters can disagree.
- Keeping the heuristics and adding stamps beside them: each #689 case would need its own rule.

### D13. First sync of a category after the update

`categoriesSyncedOnce` already records which categories a device has synced. For a category in
it, unstamped local values are a copy of old server state: they are not sent, and the snapshot
replaces them. For a category not in it, the device queues each local value stamped 0, which
fills only fields the backend holds no stamp for. This is a rule for every first sync, not a
one-time migration, so it lives in `AppState+BackendSync.swift`, not `Migrations/`.

Lost:
- Sending everything stamped 0: under the old backend a clear deleted the record, so a mark
  cleared on another device would come back.
- Sending nothing: a device that never synced a category would lose its local values at first
  sync, where today the re-enable prompt offered Use Local.

### D14. One refresh pipeline on iOS

A refresh entry on `AppState` runs: stored data is already on screen; `cloudSyncCoordinator`
drains, then `syncOverridesFromBackend(followUpIfBusy: true)`; then course selection
(`syncCoursesIfAuthenticated`), Moodle (`AppServiceBridge.fetchAssignments`) and the calendar in
parallel. `backgroundSync` becomes that pipeline. `HomeView.refreshable`, which today fires
`HomeViewModel.triggerRefresh` and `syncOverridesFromBackend` side by side, calls it, as do the
Mac's Refresh (`MacRootView`) and the Calendar, Class Table and Score pulls before their own
fetch. Revision polling and sync pushes still run the TigerSync step alone. `FullSyncGate`
already joins concurrent pulls.

Lost:
- Keeping the parallel start and relying on the base layer alone: the owner fixed the order.
- Starting school fetches only after a successful TigerSync: an unreachable backend would block
  school data.

### D15. "Use Server / Use Local": removed

Two prompts exist: the per-assignment alert after a full sync (`resolveSyncConflicts`, shown from
`HomeView` and `MacHomeView`) and the re-enable check (`checkPendingConflicts`,
`resolveReenableConflict`, shown from `CloudSyncSettingsView` and `MacTigerSyncSettingsView`).
The first is decided away by the clock. The second goes too, with
`pendingConflictCategories`, `UseLocalHold`, `ConflictCheckRetry`, `ReenableConflict`,
`keepLocalCourses` and `queueLocalEdits`. Turning sync on sends the stamped unsent edits and
applies the snapshot (D12, D13). What is lost: a deliberate "make this device match the server"
or "push this device over the server" for data never edited since the update.

Not recommended:
- Keep the prompt only when unstamped local data differs from the server: it keeps the whole
  check machinery for data that ages out, and asks a question the clock answers for stamped data.
- A settings action "Replace this device's data with TigerSync's": possible later if wanted; it
  needs no prompt and no state.

`pendingConflictCategories` and the other orphaned keys (`courseRowIdsSeen`, `semesterResetAt`)
stay as harmless leftovers, as `Services/Migrations/AGENTS.md` allows.

### D16. Revision polling and push triggers

The poll schedule (`RevisionPollSchedule`), `/v3/sync/revision`, the change feed and
`ChangeFeedPlan` stay. What changes: a refused or same-content edit appends no change log entry
and queues no `sync_trigger` (`_enqueue_sync_trigger` in `server/routes/overrides.py` and the
pushes in `server/routes/sync/`), so a device's own no-op does not wake its other devices; a
snapshot is always applied and `_lastKnownRevision` always advances, since pending fields are
held per field rather than by skipping the snapshot when an edit happened during the fetch.

Lost: putting values in the change feed so clients skip the full sync. The feed carries routing
hints only (`UserChangeLog` in `server/sync/models/state.py`).

## 3. API changes

All `/v3` responses add `X-TigerSync-Clock: <int>`. New clients send `X-TigerSync-Protocol: 2`;
their writes need a stamp (422 without). Responses only add fields, so released apps read them as
before; the stamps below are returned with or without the header, and only the tombstone window
and kinds, the upload `adds` and the delete `kind` depend on it.

| Endpoint | Request (protocol 2) | Response adds |
|---|---|---|
| `PATCH /v3/sync/assignments/{moodle_assignment_id}/override` | `hlc` | `local_status`, `local_status_hlc`, `applied` |
| `PATCH /v3/sync/courses/{moodle_id}/override` | `hlc` for the fields sent | `color_hex_hlc`, `custom_names_hlc` (locale to stamp), `ignore_assignments_hlc`, `applied` (field names) |
| `PUT /v3/sync/holiday-overrides/{holiday_id}` | `hlc` | `hlc`, `applied` |
| `DELETE /v3/sync/courses/{course_key}` | `?hlc=&kind=hide\|remove` | `applied`, `hlc` |
| `DELETE /v3/sync/courses[?semester=]` | `?hlc=` | `reset_hlc` |
| `POST /v3/sync/courses/upload` | `adds: [{course_key, hlc}]` (max 50) in place of `force_keys` | `adds: [{course_key, applied, hlc}]` |
| `GET /v3/sync/full` | header only | `server_hlc`; `*_hlc` beside each stamped field; `courses[].added_hlc`; every tombstone with `hlc` and `kind` (`hide`, `remove`, `reset`); `term_resets` (semester to stamp); `courses_reset_hlc`; `holiday_overrides[].hlc` |

`POST /v3/sync/assignments/upload`, `GET /v3/sync` and `GET /v3/sync/revision` keep their shape.
`initial-upload` and the `academics.py` PUTs go through the same merge; a value sent without a
time counts as oldest instead of `now`.

## 4. Migration Plan

Backend, one Alembic revision, additive:
1. Add `user_course_overrides.custom_names_updated_at` (JSONB, default `{}`), filled per locale
   present in `custom_names` from `custom_name_updated_at`, else the row's `updated_at`.
2. Fill a missing stamp beside a set value with the row's `updated_at`: colour, name, a true
   ignore setting, a mark other than `none`, a note.
3. Add `user_courses.added_at`, filled from `created_at` where `source = 'user_added'`.
4. Create `user_semester_resets`, filled with the latest `deleted_at` of each user's and term's
   `deleted_by_reset` tombstones.

Downgrade drops what the upgrade added; today's code ignores the new columns, so a code rollback
needs no data rollback. Rows kept as `none` read correctly in today's code.

Devices: nothing is rewritten. The outbox's stamps are the queue times (D3); unstamped values
follow D13.

Rollout:
1. Backend ships both protocols and deploys; released apps see today's behavior, plus the
   header they ignore.
2. iOS ships protocol 2.
3. Android ships protocol 2.
4. Later, once no active device reports a version older than both protocol-2 releases
   (`user_devices.app_version`), the legacy branches (`force_keys`, author releases, per-course
   reset tombstones, the 30-day filter) can go, as a separate change.

## 5. Android parity

Read-only survey for its maintainer; Android owns the implementation.

- Clock: persist last issued, last seen and the last header heard with its device time, for
  D1's cap (`data/preferences/AppPreferences`), read
  `X-TigerSync-Clock` and send `X-TigerSync-Protocol: 2` in `push/PushApiClient.kt` and
  `push/SyncApiClient.kt`.
- Writes carry the edit's stamp: `patchAssignmentOverride`, `patchCourseOverride`,
  `putHolidayOverride`, `deleteCourse` (with `kind`), `deleteAllCourses`, and `uploadCourses`
  with `adds` (`push/CourseUploadPayload.kt`).
- Unsent edits: in-flight ids live in memory (`HomeSyncState.pendingOverrides`), so an edit made
  offline is lost when the process dies. Android needs a persisted queue of stamped edits, one
  per field, kept while sync or the category is off. This is the largest Android item.
- Pull: `SyncApiClient.parseFullSync` reads the stamps, tombstone kinds and resets; apply the
  D12 rule in `HomeBackendSync.pull`.
- Remove the per-assignment conflict (`AssignmentOverrideReconciler` conflicts, the dialog in
  `HomeScreen`, `HomeBackendSync.applyResolution`), and, if the owner agrees to D15, the
  re-enable dialog in `CloudSyncSettingsScreen`.
- `CourseSyncReconciler`: membership from tombstones, kinds and resets instead of its own rules.
- Order: `HomeViewModel.load`, `refresh`, `fetchData` and `notification/BackgroundSyncWorker`
  pull before the school fetch.

## 6. Test plan

Backend (`uv run pytest server/tests/` against a throwaway Postgres):
- Clock: refuse past now + 5 s with `clock_ahead` and nothing written, old values kept,
  microsecond round trip, header on 200, 404, 409 and 422.
- Merge: later wins, tie keeps, same content raises the stamp without a change log entry, a
  field without a stamp takes 0, per-locale names.
- Concurrency: two sessions writing one field at once; the later stamp is stored.
- Routes: each PATCH, PUT and DELETE with older and newer stamps, the winner in the response,
  422 without a stamp under protocol 2, arrival stamping without it, no `sync_trigger` for a
  refused edit, `none` kept and an older mark refused.
- Membership: each #689 case (delete queued before a re-add elsewhere, reset then a stale hide
  or add, a roster listing a hidden course, removal then a roster listing it, a lost reply and a
  retry), and a released app's upload still bound by a protocol-2 reset. Arrival orders: an add,
  an older add, then a hide between them; a reset arriving after a later add, hide and colour,
  and after a later reset; a removal, a roster listing the course, then an older hide.
- Snapshot ordering: `server_hlc` not later than the header of a write committed before it.
- Snapshot: stamps and kinds for protocol 2, today's shape without the header.
- Migration: upgrade and downgrade on seeded rows.

iOS (`xcodebuild test ... -only-testing:TigerDuckTests`):
- `SyncClock`: stamping rule, persistence, never lowered, ignored before first unlock.
- Outbox: a legacy entry keeps its stamp; entries kept while off; cleared on sign-out.
- Requests: protocol header and stamps on every write (a stub `URLProtocol`, as
  `swift/TigerDuckTests/SettingsAPIStub.swift` does).
- Pull: held when queued, held while the snapshot's `server_hlc` is not later than the ack's
  header, otherwise adopted, absence after a hide or reset included; a write response does not
  replace an edit made while the write was in flight.
- Courses: reconcile from tombstones, kinds and resets; the #689 cases end to end against a fake
  backend.
- Refresh order: a fake school fetch starts only after the TigerSync step returns or fails.
- Two devices by hand before release: each #689 case and a pull while the other device edits.

Android (`./gradlew :app:testPlayDebugUnitTest`): reconciler and parser tests for the same
cases.

Across clients by hand after each release: a released Android with a new iPhone on the deployed
backend, for colour, mark, hide and reset.

## Risks / Trade-offs

- [A device whose clock is behind loses to edits made elsewhere during the lag while offline]
  → stamps never fall below the last server value seen, so the window is at most the clock's lag
  and at most the time since that device last synced; accepted with last-writer-wins.
- [A clock up to five seconds ahead beats a later honest edit inside that window] → the skew
  constant; anything further ahead is refused and re-stamped.
- [An old app's late retry wins over a newer edit] → today's behavior, ends as apps update (D8).
- [Local changes made while sync was off before the update lose to the server, and without the
  prompt (D15) cannot be kept] → the owner's oldest rule; D13 still fills fields the server
  lacks.
- [Hiding a course drops its colour and name, so a re-add starts without them] → today's
  behavior, out of scope.
- [A user's TigerSync writes serialize on one lock] → they already do at the change log append;
  each request holds it briefly.
- [Removed prompts leave unused strings] → remove the keys in an `app-translation` pull request
  and bump the submodule.

## Owner decisions

1. Re-enable "Use Server / Use Local" (D15): removed.
2. The school fetches wait for TigerSync at most 3 seconds, then start; TigerSync keeps running
   and the base layer keeps user choices safe whatever finishes first.
3. The legacy branches (Rollout step 4) go in a separate change once no active device has
   reported an older version for 30 days.
4. `fix/course-outbox-ordering` (#689) merges into the current patch release. The iOS course
   group removes its heuristics with a test per case listed in #689, then #689 and the issues
   merged into it close.
