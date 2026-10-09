# 0011. Warn on the Live Activity settings screen only while Live Activities are off

Status: accepted

## Context

`LiveActivitySettingsView` shows a link row to `NotificationPermissionSettingsView` when a
system permission keeps its settings from producing anything. Two system authorizations are
involved: notifications (`UNUserNotificationCenter.current().notificationSettings()`) and Live
Activities (`ActivityAuthorizationInfo().areActivitiesEnabled`). On Android a Live Update is a
notification, so POST_NOTIFICATIONS stops it outright and the notification permission is a
gate there.

## Decision

- `LiveActivitySettingsView.permissionGapStatus(liveActivitiesEnabled:)` gates only on
  `ActivityAuthorizationInfo().areActivitiesEnabled`. When it is false,
  `LiveActivityCoordinator.apply` returns before requesting anything, so no setting on the
  screen can produce a Live Activity.
- It returns `nil` when the user is not blocked: no empty state and no permanent row.
- Notification authorization is not a gate. ActivityKit is authorized separately, by the
  per-app Live Activities switch in Settings (Apple's `ActivityAuthorizationInfo`
  documentation): `Activity.request` succeeds with notifications denied, and the activity
  appears on the Lock Screen and in the Dynamic Island. Notification authorization keeps its
  row on `NotificationPermissionSettingsView`, next to the reminders that do need it.
- The function is static and internal and takes a plain `Bool`, so a test can pin it without
  constructing a view, store or environment, as with `formatHoursAndMinutes` and the two
  mappings on `NotificationPermissionSettingsView`. It returns
  `NotificationPermissionSettingsView.RowStatus` instead of describing the same two states a
  second way.

## Alternatives

- Gating on notification authorization too, as Android does: on iOS that would put a permanent
  warning on a screen that works, because Live Activities still start with notifications denied.

## Consequences

- The iOS and Android settings screens differ here, and a parity change must keep the difference.
- `LiveActivityPermissionGapTests` (`swift/TigerDuckTests/LiveActivitySettingsViewTests.swift`)
  pins the shown and hidden cases.
