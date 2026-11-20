# Live Activity

Rules for `swift/TigerDuck/Devices/LiveActivity/`, the app side of the Dynamic Island and
lock-screen activities. The extension UI is in `swift/TigerDuckLiveActivity/`. The backend sends
assignment reminders; nothing here schedules them.

- Courses come from `CanonicalCourseProvider`, so Home, Class Table and Live Activity agree.
- `Backend/Push/ScheduleSyncService.swift` builds the 48-hour event list it sends to the backend
  with these resolvers, so a resolver change also changes what the server pushes.
- An activity ends only for a reason `docs/decisions/0010-live-activity-end-policy.md` lists,
  never for not being the current resolved target: several run at once, pre-started by push.
- Ask for notification permission only on an explicit user action, never from a background
  scheduling path.
