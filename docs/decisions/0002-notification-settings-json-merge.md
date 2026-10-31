# 0002. Optional fields and a JSON-level merge for the notification settings document

Status: accepted

## Context

The `notification` namespace of the settings document (`GET/PUT /v3/settings/notification`,
read and written through `SettingsDocumentClient`) has three writers: this app, the Android
app and the backend's defaults. The backend accepts any JSON object without validating it, and
each writer learns new sections and fields at its own pace.

This app owns the `assignments`, `live_activity` and `courses` sections, with the field mapping
fixed in `NotificationSettingsSync.LocalPreferences`; any other section belongs to Android or a
later build. Only the iOS build syncs the document: every synced field lives on
`LiveActivityPreferencesStore`, which `AppState` creates only under `#if os(iOS)`.

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
- `courses` has no device switch: it syncs whenever cloud sync is on. The backend reads a
  missing field as on and 10 minutes before (`course_reminder_default_offsets_minutes`), the
  app's defaults too. `reminder_offsets_minutes` holds the one class reminder lead time the app
  offers, in whole minutes, as Android types the key `List<Int>?`. A push writes it only when the
  user picked a lead time on this device since the list was last adopted
  (`LiveActivityPreferencesStore.hasPickedClassReminderLead`), or when the document has none;
  otherwise the merge keeps the document's list, which may hold a value the app does not offer
  or several, so a push for another setting never replaces another client's choice. A pull
  shows the list's smallest value when the app offers it.
- A push sends only what this device changed. `notificationSettingsSyncedPreferences` keeps the
  settings as the device last synced them: what a write that landed sent, or what a reconcile
  settled on. A push writes a field when the device's value differs from that copy or when the
  document lacks the field, and a section the document lacks goes whole; every other field stays
  as the document holds it, on the first write and on the 409 retry, so two devices that change
  different fields of one section both keep their change. The two offset lists count as one
  field. With no copy stored, after a sign-out or an upgrade, no field counts as changed: an
  unsent edit cannot be told from a value another device changed since, and that newer value
  wins over the edit. Turning a device switch back on makes that section's values the copy, so a
  push leaves the section as the document holds it, and a reconcile adopts it. Sign-out clears
  the copy.

## Alternatives

- Re-encoding a typed struct on push: it would delete every key the struct does not carry, such
  as a section another client adds or a field a newer build adds to one this app owns. The
  backend reads a missing `courses` field as its default (`server/push/course_reminders.py` in
  `tigerduck-app/tigerduck-backend`), so losing one silently resets the user's class reminders,
  with nothing on screen to say so.
- A typed struct with a bag of unknown keys: it needs hand-written `init(from:)` and
  `encode(to:)` on the document and on every nested section, because unknown keys appear inside
  sections too, plus a `Sendable`, `Equatable` box for arbitrary values. The client already
  hands over the raw `Data`, so the dictionary merge costs nothing extra.

## Consequences

- New fields must be Optional, and a push must go through the merge.
- A new synced field needs a property on `LocalPreferences` and a case in its `replacing`; a
  copy stored by an earlier build then fails to decode and counts as no copy.
- `NotificationSettingsSyncTests` pins the merge, the preserved minute values, the hours mirror,
  the class reminder offsets kept for another client and the fields a push leaves alone.
