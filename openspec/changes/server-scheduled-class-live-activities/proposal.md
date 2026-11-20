# Proposal

## Why

Class reminders and the class Live Activity overlap, and the owner chose to keep only the Live
Activity. Today it cannot stand alone: the backend starts a class activity only from the list each
iPhone uploads for the next 48 hours (`ScheduleSyncService.horizon`), so a phone whose app has not
run lately gets none, while class reminders come from the timetable the backend stores. In the 7
days to 2026-11-20, 505 users were sent a class reminder and only 210 of them a `classPreparing`
start; 68% of the 5,807 reminders went out on a day with no start for that user.

## What Changes

- iOS 4.0.0 reports each device's Live Activity profile to the backend on the existing device
  preferences request: the in-app switch, the system's Live Activities permission, the class
  scenarios, the class lead time and the Live Activity accent.
- The backend builds each class's `classPreparing` and `inClass` starts itself from
  `user_courses`, with the occurrence rules class reminders use, for every iPhone or iPad that
  reports a profile, has Live Activities, cloud sync and course sync on, and has a push-to-start
  token. It checks each start again right before sending and drops it when the check cannot
  answer.
- For such a device the backend ignores the class events the app uploads and keeps the jobs it
  filed. Devices without a profile (released apps) and devices with course sync off keep today's
  uploaded schedule. Starts keep today's job keys, so the two sources never hold two starts of one
  class.
- Before going live, the backend compares what it would build with what apps upload (shadow
  mode) and counts matches and differences per field.
- **BREAKING (iOS)**: iOS 4.0.0 removes the class reminder setting, its stored defaults, its
  sync of the `courses` section of the `notification` document, its What's New page and its debug
  push. Devices that report a profile stop getting class reminders once the owner switches it on.
- **BREAKING (backend)**: at a date the owner sets for released apps, the backend removes the
  class reminder scan, its `course` push channel, its copy, settings, portal count and docs.
- Each device's class starts no longer depend on when its app last ran. A device with Live
  Activities off in iOS Settings or in the app gets nothing before class, as the owner accepted.

Out of scope:

- Android. It posts its own class reminders and reads and writes the `courses` section; this
  change leaves both, and its maintainer decides on them.
- Assignment starts (`assignmentUrgent`) and assignment reminders: unchanged, still uploaded.
- Stopping the iOS class event upload; 4.0.0 keeps it as the fallback for devices the backend
  does not serve and as the comparison input.
- Updating a running activity by push, and Live Activity channels (broadcast).
- New settings screens, and any change to the in-app Live Activity settings.
- Club activities: no class Live Activity covers them today.

## Capabilities

### New Capabilities

- `class-live-activities`: which devices the backend files class Live Activity starts for, what
  each start carries and when it is sent or dropped, how that coexists with uploaded schedules,
  and the end of class reminders on iOS.

### Modified Capabilities

None.

## Impact

- tigerduck-backend `server/`: a shared class meeting module moved out of
  `push/course_reminders.py` (`class_meetings`, `changed_meeting`, `PERIOD_RANK`) and extended
  with period end times, meeting fragments and block rooms; a `live_activity_profile` column on
  `user_devices` and its field on `PATCH /devices/{id}/preferences`; a class start scan job;
  `routes/schedule_v3.py`; `push/pipeline.py`'s check before a class start;
  `push/job_payloads.py`; settings, metrics, `server/AGENTS.md`, `MIGRATE.md`,
  `docs/api-v4.md` and `docs/push-notification-flows.drawio`. Later, removal of
  `push/course_reminders.py`'s scan and `push/notification_copy.py`'s class reminder, and the
  portal's class reminder count and labels.
- iOS `swift/TigerDuck/`: `Backend/Push/PushDeviceRequests+Preferences.swift` and the device
  preferences DTO; `Devices/LiveActivity/Preferences/LiveActivityPreferencesStore.swift`;
  `Backend/Sync/NotificationSettings*.swift`; the class reminder settings screen, row and place;
  `App/AppDefaults.swift`, `App/AppConstants.swift`; `Features/Updates/`; `whatsnew.json`; a
  cleanup migration; tests; `docs/account-state.md`; ADRs 0002 and 0012 and a new ADR.
- Strings: none added or removed; the class reminder keys stay because Android uses them.
- Production: more class starts (every served device, not only recently active ones) and fewer
  alerts on the `course` channel, then none.
