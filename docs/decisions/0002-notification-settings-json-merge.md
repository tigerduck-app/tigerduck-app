# 0002. Optional fields and a JSON-level merge for the notification settings document

Status: accepted

## Context

The `notification` namespace of the settings document (`GET/PUT /v3/settings/notification`,
read and written through `SettingsDocumentClient`) has three writers: this app, the Android
app and the backend's defaults. The backend accepts any JSON object without validating it, and
each writer learns new sections and fields at its own pace.

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
  against the document actually written, including after a 409 rebase. Android does the same
  (`push/NotificationSettingsSync.kt`). `reminder_offsets_hours` is derived from the merged
  minutes and holds only whole hours of at least one, for readers that predate the minutes
  field.

## Alternatives

- A typed struct with a bag of unknown keys: it needs hand-written `init(from:)` and
  `encode(to:)` on the document and on every nested section, because unknown keys appear inside
  sections too, plus a `Sendable`, `Equatable` box for arbitrary values. The client already
  hands over the raw `Data`, so the dictionary merge costs nothing extra.

## Consequences

- New fields must be Optional, and a push must go through the merge.
- `NotificationSettingsSyncTests` pins the merge, the preserved minute values and the hours
  mirror.
