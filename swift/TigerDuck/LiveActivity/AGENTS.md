# LIVE ACTIVITY KNOWLEDGE BASE

## OVERVIEW
`LiveActivity/` is a self-contained subsystem for Dynamic Island / lock-screen state, reminder scheduling, and scenario resolution based on courses and assignments.

## STRUCTURE
```text
LiveActivity/
├── Models/        # snapshots, scenario kinds, reminder payloads, offsets
├── Preferences/   # persisted user settings and invariants
├── Providers/     # canonical course source for timeline logic
├── Resolvers/     # scenario + course timeline computation
├── Runtime/       # ActivityKit lifecycle + shared snapshot storage
└── Scheduling/    # notification scheduling
```

## WHERE TO LOOK
| Task | Location | Notes |
|---|---|---|
| Activity lifecycle | `Runtime/LiveActivityCoordinator.swift` | Single-activity invariant, start/update/end |
| Widget/app shared payload | `Runtime/SharedSnapshotStore.swift` | Shared data for extension |
| Scenario decision logic | `Resolvers/LiveActivityScenarioResolver.swift` | Assignment/class/idle selection |
| Course boundary timing | `Resolvers/CourseTimelineResolver.swift` | Computes in-class / preparing transitions |
| User prefs and limits | `Preferences/LiveActivityPreferencesStore.swift` | Lead-time limits, toggle broadcasting |
| Reminder notification scheduling | `Scheduling/AssignmentReminderScheduler.swift` | No-prompt scheduling path |

## CONVENTIONS
- `AppState` orchestrates entry into this subsystem, but the subsystem owns the rules for scenario computation and scheduling behavior.
- Preference changes broadcast through `AppConstants.liveActivityPreferencesDidChange`; refresh/reschedule is intentionally debounced.
- The course source for this subsystem goes through `CanonicalCourseProvider` so Home, Class Table, and Live Activity stay aligned.

## ANTI-PATTERNS
- Do not create multiple concurrent live activities; coordinator logic assumes a single activity instance.
- Do not exceed the assignment lead-time invariant in `LiveActivityPreferencesStore` (8 hours).
- Do not prompt for notification authorization from background-safe scheduling paths; explicit user intent is required.
- Do not reschedule reminders for purely visual changes like accent-only updates.

## NOTES
- Foreground freshness uses boundary-based one-shot refresh tasks; true background correctness would require push-based updates.
- Widget extension UI lives in `swift/TigerDuckLiveActivity/`, but this directory owns the app-side state and rules that feed it.
