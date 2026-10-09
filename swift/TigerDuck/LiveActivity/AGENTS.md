# Live Activity

Rules for `swift/TigerDuck/LiveActivity/`, the app side of the Dynamic Island and lock-screen
activities: scenario resolution from courses and assignments, preferences and the ActivityKit
lifecycle. The extension UI is in `swift/TigerDuckLiveActivity/`. The backend sends assignment
reminders; nothing here schedules them.

## Conventions

- `AppState` decides when to enter this subsystem; the rules for scenarios and scheduling live
  here.
- Preference changes broadcast `AppConstants.liveActivityPreferencesDidChange`, and the refresh
  they trigger is debounced.
- Courses come from `CanonicalCourseProvider`, so Home, Class Table and Live Activity agree.

## Anti-patterns

- Do not end an activity only because it is not the current resolved target. Several can run at
  once: server push-to-start pre-starts later ones (a classPreparing activity and its inClass
  follow-up are distinct), and each is ended by its server end job or its own countdown. The
  coordinator ends only expired activities, duplicate copies of one `composedActivityId`, class
  activities on a day classes do not meet (by the academic calendar and the user's "still have
  class" choices), and all of them while Live Activity is unavailable.
- Do not exceed the 8-hour assignment lead-time limit in `LiveActivityPreferencesStore`.
- Do not ask for notification permission from background scheduling paths; it needs an explicit
  user action.
- Do not reschedule for purely visual changes such as accent-only updates.

## Gotchas

- Foreground freshness relies on one-shot refresh tasks at class boundaries; correctness in the
  background would need push updates.
