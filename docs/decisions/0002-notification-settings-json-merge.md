# 0002. Optional fields and a JSON-level merge for the notification settings document

Status: accepted

## Context

The `notification` namespace of the settings document (`GET/PUT /v3/settings/notification`,
read and written through `SettingsDocumentClient`) has three writers: this app, the Android
app and the backend's defaults. The backend accepts any JSON object without validating it, and
each writer learns new sections and fields at its own pace.

This app owns only the `assignments` and `live_activity` sections, with the field mapping fixed
in `NotificationSettingsSync.LocalPreferences`; `courses` belongs to the course-reminder
feature, and any other section to Android or a later build. Only the iOS build syncs the
document: every synced field lives on `LiveActivityPreferencesStore`, which `AppState` creates
only under `#if os(iOS)`.

## Decision

- Every section of `NotificationSettingsDocument`, and every field inside each section, is
  Optional. A missing key means the server says nothing about that field, and
  `NotificationSettingsSync.apply` leaves the local value alone. A required property would make
  synthesized `Decodable` throw `keyNotFound` for any document another writer created first,
  which on the push path is an abort with only a log line, repeated on every push.
- A push merges at the JSON level: `merging(_:into:)` in `AppState+NotificationSettings.swift`
  splices the app's sections over the document it read, key by key and recursively, so keys the
  app does not know survive at the top level and inside the sections it owns. Arrays are
  replaced whole, because each one is a complete set of user choices and a union could not
  express a removal.
- `reminder_offsets_minutes` is written outright, so the merge cannot protect values in it: the
  app writes back minute values that no `AssignmentReminderOffset` case represents, recomputed
  against the document actually written, including after a 409 rebase. A value that a case
  represents is not foreign, so deselecting it still removes it. Android does the same
  (`push/NotificationSettingsSync.kt` in `tigerduck-app/tigerduck-app-android`).
- `reminder_offsets_hours`, for readers that predate the minutes field, is derived from the
  merged minutes so the two never disagree, and holds only whole hours of at least one: the
  four sub-hour offsets would all truncate to 0, and such a reader would take 0 or a negative
  as a reminder at or after the deadline. Those values stay in the minutes array only. A
  foreign value found only in the hours field is not kept: every writer that knows the minutes
  field mirrors into it, so it can only come from a client older than that field. Both arrays
  are written descending, so the document is deterministic (`Set` order is not stable).

## Alternatives

- Re-encoding a typed struct on push: it would delete every key the struct does not carry, and
  the backend reads a missing `courses` section as its defaults (`server/push/course_reminders.py`
  in `tigerduck-app/tigerduck-backend`), so losing it silently resets the user's class reminders,
  with nothing on screen to say so.
- A typed struct with a bag of unknown keys: it needs hand-written `init(from:)` and
  `encode(to:)` on the document and on every nested section, because unknown keys appear inside
  sections too, plus a `Sendable`, `Equatable` box for arbitrary values. The client already
  hands over the raw `Data`, so the dictionary merge costs nothing extra.

## Consequences

- New fields must be Optional, and a push must go through the merge.
- `NotificationSettingsSyncTests` pins the merge, the preserved minute values and the hours
  mirror.
