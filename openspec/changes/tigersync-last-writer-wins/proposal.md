# Proposal

## Why

TigerSync settles disagreements between devices with arrival order on the server, device-side
guesses (edit generations, grace windows, row-id comparisons, device-versus-server time) and two
"Use Server / Use Local" prompts. Each race fixed so far (#666, #689 and the issues merged into
it) has added another guess, and the school sync runs beside TigerSync, so a slow pull can let
fresh school data replace a choice the user made on another device. Recording when each edit was
made, and letting the newer edit win field by field, replaces the guesses with one rule that both
apps and the backend share.

## What Changes

- Every user edit carries a hybrid logical clock (HLC) value, per item and per field. Views,
  school fetches and bulk uploads never stamp anything. Deletions and resets are timestamped
  tombstones.
- The backend keeps the newer value per field, comparing and writing under the user's sync lock.
  Equal content with another timestamp keeps the value and the later time, with no prompt.
  A timestamp too far ahead is clamped to server time plus five seconds.
- The override, course delete, course reset, course upload and holiday endpoints accept the
  clock; `/v3/sync/full` returns it for every field and tombstone, and keeps every tombstone
  instead of the last 30 days. Every `/v3` response carries the server clock.
- Requests from released apps, which send no clock, keep today's behavior: their single edits
  are stamped with the time they arrive, their bulk uploads count as oldest.
- Clearing an assignment mark keeps the row with `none` and its time instead of deleting it, so
  an older mark cannot come back.
- Course membership becomes a user layer over the school roster: adds, hides and removals carry
  the clock, a term reset is one timestamp, and a school upload never brings back what the user
  hid. A reset no longer depends on which device wrote it.
- iOS: refresh runs local state, then TigerSync, then course selection, Moodle and grades. The
  outbox becomes the record of unsent edits, kept while TigerSync or a category is off.
- **BREAKING (UI)**: the per-assignment conflict alert goes away. Removing the re-enable
  "Use Server / Use Local" prompt is recommended and needs the owner's confirmation.
- iOS drops the race heuristics that the `fix/course-outbox-ordering` branch (#689) adds or
  extends; that branch is superseded.
- Android makes the same client changes (listed in design.md); its maintainer implements them.

## Capabilities

### New Capabilities
- `tigersync-clock`: the hybrid logical clock: format, tick, where each side keeps it, how a
  client learns server time, and the skew clamp.
- `tigersync-merge`: per-item, per-field last-writer-wins on the backend and in the apps:
  inventory of synced fields, tombstones and resets, compatibility with released apps, and
  migration of existing server and device data.
- `tigersync-refresh-order`: the order of local state, TigerSync and the school fetches on
  launch and refresh, and the school base layer under user overrides.

### Modified Capabilities

None. No existing spec covers sync.

## Out of scope

- Settings documents (`/v3/settings/{namespace}`): they keep revision compare-and-swap and the
  JSON-level merge of `docs/decisions/0002-notification-settings-json-merge.md`.
- Bulletin subscriptions and read state, which are per device and not part of TigerSync.
- Device preferences (`/v3/devices`) and the per-device sync switches.
- Skipped class dates: both apps keep them on the device; the backend's skipped-date routes are
  unused and stay as they are.
- Removing school rows that a newer roster no longer lists; the server keeps upserting as today.
- Keeping a course's colour, name and ignore setting through a hide and a re-add; they still go
  with the row, as today.
- Implementing any of it: this change is the plan. The backend comes first, then iOS, then
  Android.

## Impact

- Backend (`tigerduck-backend`): `server/sync/merge.py`, `server/routes/overrides.py`,
  `server/routes/sync/{courses,uploads,snapshot}.py`, `server/routes/holiday_overrides.py`,
  `server/sync/serializers.py`, `server/main.py`, `server/sync/models/courses.py`, one Alembic
  migration, tests under `server/tests/`.
- iOS: `swift/TigerDuck/Services/CloudSync/`, `Services/Push/PushAPIClient.swift`,
  `App/AppState+BackendSync.swift`, `+Conflicts.swift`, `+CourseReconcile.swift`,
  `+RevisionPolling.swift`, the refresh entry points (`HomeView`, `TigerDuckApp`, `MacRootView`),
  settings views that host the prompts, tests in `swift/TigerDuckTests/`.
- Android (`tigerduck-app-android`): `push/PushApiClient.kt`, `push/SyncApiClient.kt`,
  `ui/screen/home/*Reconciler.kt`, `HomeBackendSync.kt`, `HomeViewModel.kt`,
  `CloudSyncSettingsScreen.kt`.
- Localization: the conflict strings become unused in `app-translation`.
