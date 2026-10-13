# 0012. Live Activity requires course sync

Status: accepted

## Context

Live Activity has its own switch, `isLiveActivityEnabled` on `LiveActivityPreferencesStore`.
Course sync ("Sync course information", `cloudSyncEnabled`) lives on `AppState`, and its
footer, `sync_courses_footer_platform_note`, tells users that turning it off also disables
Live Activity and assignment due reminders. An activity can start on the device from the
resolved scenario or on the server by push-to-start from the schedule this device uploads,
and `LiveActivityCoordinator` keeps or ends whatever ActivityKit is running.

## Decision

- `effectiveLiveActivityEnabled(isLiveActivityEnabled:cloudSyncEnabled:)` in
  `swift/TigerDuck/LiveActivity/Preferences/LiveActivityPreferencesStore.swift` is the one place
  the combined answer is computed. Every reader calls it, and while it is false:
  - `LiveActivityScenarioResolver.resolve` returns nil, so the app starts nothing.
  - `ScheduleSyncService.Inputs.liveActivityAvailable` makes the upload an empty list, which
    cancels the push-to-start jobs this device queued before.
  - `LiveActivityCoordinator` asks `AppState.isLiveActivityAvailable` on every prune and
    activity-observer pass and ends every activity, as
    docs/decisions/0010-live-activity-end-policy.md describes.
- Both inputs are parameters, since `AppState` owns `cloudSyncEnabled`, and a free function
  over explicit inputs lets a plain unit test call it without constructing anything, the same
  shape as Android's `effectiveCloudSyncEnabled`.
- It reads both inputs and writes neither: suppressing Live Activity while sync is off never
  persists `isLiveActivityEnabled = false`, so turning sync back on restores the user's choice.

## Alternatives

- Writing `isLiveActivityEnabled = false` when sync turns off: turning sync back on would
  silently lose the user's own setting.
- Combining the two flags at each call site, where the readers could drift apart.

## Consequences

- New code that starts, keeps or schedules a Live Activity asks `effectiveLiveActivityEnabled`,
  directly or through `AppState.isLiveActivityAvailable`.
- Settings disables the Live Activity row while course sync is off.
- `LiveActivitySyncGateTests` pins the function and the resolver, `ScheduleSyncServiceTests` the
  schedule upload, and `LiveActivityCoordinatorTests` the end rule while Live Activity is
  unavailable.
