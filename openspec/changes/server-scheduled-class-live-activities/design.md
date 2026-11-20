# Design

## Context

See proposal.md for why. Facts below are from this repository's `dev` at 36021fac4,
tigerduck-backend `origin/dev` at 3e36e70 (backend 4.5.1 plus a CI change) and
tigerduck-app-android `origin/dev` at c8abec18d. Production numbers are the brief's, measured on
2026-11-20.

What the iOS app files today:

- `Backend/Push/ScheduleSyncService.swift::buildEvents` runs on every schedule request
  (`Backend/Push/PushScheduleSync.swift`: `requestSync`, and `sendAfterSyncTrigger` after a
  background sync push). Its timeline is `CourseTimelineResolver()` with `dayRadius: 1`, so the
  list holds class starts from now to the end of tomorrow in Taipei, capped by `horizon` (48 h).
  It leaves out skipped or cancelled slots, days `AcademicCalendar.isClassDay(_:optedIn:)` rejects
  and slots whose day belongs to another term. `classPreparing` fires at the start minus
  `classPreparingLeadTime`, or 5 s from now when that has passed and the class is over 60 s away;
  `inClass` fires at the start. The list is empty while `effectiveLiveActivityEnabled` is false
  (docs/decisions/0012-live-activity-requires-course-sync.md).
- Courses come from `CanonicalCourseProvider`: school courses plus hand-added ones, minus hidden
  ones, with the custom name for the device's course language
  (`Persistence/CourseFiles.swift::loadCourseCustomNamesFlat`).
- `NameAbbrService.relabelInPlace` rewrites each stored `courseName`, `classroom` and
  `classroomMap` by the device's language and three device settings: `useEnglishCourseAbbreviation`,
  `useEnglishClassroomAbbreviation` (both default true) and `classroomMandarinDisplay`, from the
  bundled `class-name-abbr.json` and `classroom-name-abbr.json`. `SchoolDataUploader` uploads
  those rewritten values, with `course_name_en` nil.
- A slot's id is `{courseNo}_{yyyyMMdd}_{first period}`. `Models/Domain/CourseMeeting.swift`
  splits a meeting into fragments, each with its own id, where a course change cancels or gives a
  new room to part of it; a fragment's room is `CourseBlockRoom.room` over `classroomMap`, else
  the deduplicated `classroom`.
- `isLiveActivityEnabled` is device-only and never sent. `Defaults[.syncLiveActivity]`, sent as
  `sync_live_activity`, only decides whether this device syncs the `live_activity` section of the
  `notification` document (`Backend/Sync/NotificationSettingsSyncer.swift`). The accent
  (`AppPreferences.accentColorHex`, `deviceAccents.liveActivities`) is device-local; iOS syncs only
  the `notification` and `club_subscriptions` documents.
- `PushTokenRelay` relays the push-to-start token only once `areActivitiesEnabled` is true, and
  the app never withdraws it when Live Activities are turned off later.
- Class reminders: `LiveActivityPreferencesStore.isClassReminderEnabled` (default true),
  `classReminderLeadMinutes` (default 10; 5, 10, 15, 30 or 60) and `hasPickedClassReminderLead`,
  synced as the `courses` section (`NotificationSettingsLocalPreferences.coursesSection`), which
  `NotificationSettingsReconcile` seeds when the document lacks it.

What the backend does today:

- `server/routes/schedule_v3.py` files each event as a `push_jobs` row on channel `schedule`, key
  `schedule:{device_id}:{source_id}:{scenario}` (`server/push/dedupe.py`). A pending start the
  upload repeats takes its fire time and snapshot; one it leaves out is cancelled.
- `server/push/pipeline.py::_materialize`, before a class start's first delivery: `_classes_quiet`
  (outside every term, or a holiday the user did not opt into) cancels it;
  `_held_by_course_changes` runs `server/push/class_starts.py::recheck_class_start` (a cancelled
  class cancels it, a new room or time rewrites it, a later start puts it back);
  `_activity_already_registered` cancels it as `activity_already_running`. It goes to the device's
  `push_to_start` token; with none it fails `no_active_tokens`. No `user_devices` flag is read for
  a start.
- `server/push/job_payloads.py::build_apns_for_job` sends the start with priority 10, an alert of
  the snapshot's title and subtitle and no `sound` key, `stale-date` at `countdownTarget` and an
  APNs expiration 24 h out.
- `server/push/course_reminders.py::scan_course_reminders` runs every 600 s over a 48 h window:
  enrolled courses with a schedule, each day's term (`current_term_code`), `outside_term`,
  holidays and `user_holiday_overrides`, `user_course_skipped_dates` and course changes
  (`changed_meeting`), for users with an iPhone or iPad holding a standard token, at the offsets
  of the document's `courses` section (default `[10]`). It has period start times only
  (`settings.course_period_start_times`); its body uses the flat `classroom`. Two pieces are shared
  already: `server/course_announcements/checks.py` imports `PERIOD_RANK` from it.
- `user_courses` holds `course_name` and `classroom`/`classroom_map` as the last uploading device
  showed them, `instructors`, `schedule_json`, `source` and `course_key` (`client:{term}:{no}`);
  `course_no` may be NULL for a hand-added row. Hiding a course deletes its row
  (`server/routes/sync/courses.py`). `user_course_overrides.custom_names` holds `zh` and `en`
  names. `course_catalog_en_texts` holds each catalog course's English name.
- `user_devices` holds `platform`, `app_version`, `locale`, `cloud_sync_enabled`, `sync_courses`,
  `sync_course_names` and `sync_live_activity`; the migration that added the last says nothing on
  the server reads it. `PATCH /devices/{id}/preferences` writes them; a field left out keeps its
  value.
- `server/push/client_versions.py` gates assignment reminders by app version, failing closed.

Android posts its own class reminders, reads and writes `courses.enabled` and
`courses.reminder_offsets_minutes` (`push/NotificationSettingsSync.kt`), and plays its Live
Update's class-preparing sound only while its class reminders are off
(`liveactivity/LiveActivityNotifier.kt`). The backend sends nothing on the `course` channel to it.

## Goals / Non-Goals

**Goals:**

- A served device's class starts depend on the backend's timetable and the device's own profile,
  not on when its app last ran.
- Every start the backend builds equals the one the app would file for the same class: id,
  times, room, markers, accent.
- Released apps, and devices the backend does not serve, see no change.
- Nothing is sent that the device turned off or that a fresh check cannot confirm.

**Non-Goals:**

- Changing what a class activity shows or how it ends (docs/decisions/0010).
- Serving Android or macOS.

## Decisions

### D1. The backend files `classPreparing` and `inClass`

Both, because the app files both today and the backend takes over the whole class schedule of a
served device. Losing option: `classPreparing` alone (the device's `inClass` would then depend on
its uploads again, keeping two sources for one device).

### D2. A device profile on `user_devices`

A nullable JSONB column `live_activity_profile`, written through a `live_activity` object on
`PATCH /devices/{id}/preferences` and returned like the other flags:

| Field | iOS source |
| --- | --- |
| `enabled` | `isLiveActivityEnabled` |
| `authorized` | `ActivityAuthorizationInfo().areActivitiesEnabled` |
| `class_preparing` | `showClassPreparingScenario` |
| `in_class` | `showInClassScenario` |
| `class_preparing_lead_seconds` | `classPreparingLeadTime` (300 to 14,400) |
| `accent_hex` | `accentColorHex` (0 to 0xFFFFFF) |
| `accent_gradient` | `deviceAccents.liveActivities`, or null |

The backend validates each field at the request and refuses the object whole on a bad value.
NULL means a released app. The app sends the profile through `SendLedger` with its own channel,
so a changed profile goes out on the next preferences send, launch or sync and an unchanged one
is not resent; it sends on `liveActivityPreferencesDidChange`, an accent change and
`activityEnablementUpdates`. Losing options: the document's `live_activity` section (it is per
user, a device with `sync_live_activity` off keeps its own values, and it lacks the in-app switch
and the system permission); separate columns (seven columns and seven request fields for one
reader); a version gate as in `client_versions.py` (carries no settings).

### D3. Which devices the backend serves

One function decides, for the scan, the upload route and the send-time check: platform iPhone or
iPad, not deleted, a profile with `enabled` and `authorized`, `cloud_sync_enabled`,
`sync_courses`, an active `push_to_start` token, and mode `live` (D9). The cloud sync term is the
backend half of `effectiveLiveActivityEnabled`; course sync makes `user_courses` this device's
timetable. Losing options: serving with course sync off (the backend's rows may then not be what
this device shows; open decision O6); requiring course-name sync (a name mismatch, not a wrong
class; see O1).

### D4. Every field of a start, and what the backend lacks

| Start field | App today | Backend today | Missing, and the plan |
| --- | --- | --- | --- |
| `attributes.activityId`, `activity_id` | `{scenario}::{sourceId}` | `dedupe.activity_id` | nothing |
| `scenario` | resolver | set by the builder | nothing |
| `sourceId` | slot id per fragment | `class_meetings` gives one run of periods per meeting and its first period; `course_no` NULL on some hand-added rows | fragments (D5); course number from `course_key` |
| `title` | custom name in the device's course language, else `courseName` as relabelled on the device | `custom_names` (`zh`, `en`), `course_name` as last uploaded, catalog English name, `locale` | the device's label settings and `class-name-abbr.json` (O1) |
| `subtitle` (`HH:mm - HH:mm`) | `AppConstants.PeriodTimes` start and end, course changes | period starts only, course changes | period end times (D5) |
| `locationText` | room change, else `CourseBlockRoom.room` over the relabelled `classroomMap` | `classroom_map` and `classroom` as last uploaded, room change | the block-room rule (D5); label settings and `classroom-name-abbr.json` (O1) |
| `instructor` | `SDCourse.instructor`, nil when blank | `instructors` (iOS uploads one) | nothing |
| `countdownTarget`, `progressStart` | start, or end and start | from the times | nothing once end times exist |
| `roomChanged`, `timeChanged` | set when a change applies | changes known; `recheck_class_start` sets neither | logic only (D5) |
| `accentHex`, `accentGradient` | device accent | nothing (`color_hex` is a course colour the activity does not use) | profile (D2) |
| `deepLink` | nil for a class | nothing needed | nothing |
| fire time | start minus the device lead | document lead, user level | profile (D2) |
| whether, which scenarios | device switch, scenarios, cloud sync | `cloud_sync_enabled` only | profile (D2) |
| system permission | `areActivitiesEnabled` | a push-to-start token that outlives a later "off" | profile (D2) |
| timetable | merged school and hand-added courses minus hidden | enrolled `user_courses` with hand-added rows; a hide deletes the row | nothing with course sync on; otherwise not served (D3, O6) |
| class days | calendar, skipped dates, course changes | terms, holidays, opt-ins, skipped dates, course changes | nothing |
| alert sound | none | none | open decision O2 |

Club activities feed no class activity today, so nothing is missing for them. The course colour
is not part of an activity.

Losing options for the accent: a fixed default accent (wrong for everyone who picked another);
the extension reading the accent from the app group (the widgets' snapshot carries the widgets'
gradient choice, not the Live Activity one, and it changes how app-started activities render).

### D5. One class meeting module, extended

`class_meetings`, `changed_meeting`, `PERIOD_RANK`, the schedule parsing and the per-day term and
quiet-day rules move from `push/course_reminders.py` into a module both scans use (and
`course_announcements/checks.py` imports from), so the reminder scan's removal later leaves them.
It gains:

- `course_period_times`: each period's start and end, replacing `course_period_start_times`, with
  the values of `AppConstants.PeriodTimes` (the portal's `PERIOD_TIMES` copy already has them).
- Fragments as `CourseMeeting.fragments()` builds them: split where cancelled-ness or room
  changes between consecutive periods, each fragment's start and end clamped into the meeting,
  ids by first period.
- `CourseBlockRoom.room`: the period map's rooms for the fragment's periods, split on `、，,`,
  deduplicated in order, else the deduplicated flat classroom.
- The snapshot builder for `classPreparing` and `inClass` with `roomChanged` and `timeChanged`.

Tests share fixtures with the app's `CourseMeeting` tests where they can, since this is a port
across languages. Losing option: deriving an end as start plus 50 minutes (true of every period
today, but a second rule that silently breaks with the timetable).

### D6. Living with uploads

- Same keys: the scan files `schedule:{device}:{source_id}:{scenario}`. A pending job of that key,
  whoever filed it, is taken over (fire time, payload, and the routing key `filed_by: "server"`),
  so a device never holds two pending starts of one class and scenario.
- For a served device, `/schedule/sync` drops incoming `classPreparing` and `inClass` events after
  the comparison (D9), and its sweep cancels only that device's pending `assignmentUrgent` jobs.
  For other devices the route is unchanged.
- The scan cancels only class jobs of served devices that no longer match its build. A device
  that stops being served keeps its pending starts until its next upload replaces them; the
  send-time check (D8) cancels those it filed meanwhile.
- iOS 4.0.0 keeps uploading class events: the fallback for unserved devices, and the comparison
  input. Losing options: a separate key prefix for server jobs (an upload and the scan would then
  each file a start for one class during takeover and fallback); the app deciding whether it is
  served (a second copy of D3 on the device, wrong whenever the two disagree).

### D7. The scan

A scheduler job every `class_start_scan_interval_seconds` (300) over `class_start_window_hours`
(48), in mode `live` only: served devices, their user's eligible courses by the reminder scan's
rules, meetings and fragments, each scenario the profile has on, fire times as the app computes
them (lead passed and class over 60 s away: due now). It upserts with the `dedupe_key` predicate
(`PUSH_JOB_DEDUPE_ACTIVE_WHERE`) at `LIVE_ACTIVITY_JOB_PRIORITY`, cancels its stale pending jobs
under `SKIP LOCKED`, and writes `user_course_id` into the payload. Losing options: filing from
the preferences and course write routes too (a setting turned on in the app already starts the
activity in the foreground; the next scan files the rest); a window of the lead time only (a
course change or new term would wait for the next scan anyway).

### D8. The check before sending

For a start whose payload says `filed_by: "server"`, before its first delivery and before the
existing quiet-day, course change and already-running checks: the device is still served, its
profile has the scenario on, the `user_courses` row of `user_course_id` exists, is enrolled and
belongs to the user, and the day is not skipped. A failure cancels the job with a fixed code
(`not_served`, `scenario_off`, `course_gone`, `skipped`); a query error cancels it as
`unverified_before_send`. `filed_by` and `user_course_id` join the routing keys
`job_payloads.py` strips from the content state. Losing option: relying on the scan to cancel (up
to 5 minutes late, and a start that fires in between cannot be called back).

### D9. Mode setting and shadow comparison

`class_live_activity_mode` (`off`, `shadow`, `live`; default `off`), read at start like
`course_announcements_auto_apply`. In `shadow` and `live`, `/schedule/sync` from an iPhone or
iPad builds the device's class starts over the upload's window (start after now, today and
tomorrow in Taipei) and compares them with the uploaded class events by key: `matched`,
`app_only`, `server_only`, and for a match each differing field among `title`, `subtitle`,
`locationText`, `instructor`, `countdownTarget`, `progressStart`, `roomChanged`, `timeChanged`
and, with a profile, `accentHex`. Settings for the build: the profile, else the document's
`live_activity` section when the device syncs it, else only the scenarios the upload carries
(`server_only` is then not counted). Counts go to a Prometheus counter and one log line with
counts only, never a course name or id. In `shadow` nothing else changes. Losing options:
comparing in the scan against stored jobs (an upload replaces its jobs, so the scan sees a moving
target); storing shadow jobs (rows nobody sends, and the pipeline must learn to skip them).

### D10. A class start expires at its countdown target

APNs may hold a start for an offline phone; `build_apns_for_job` sets the expiration of a class
start no later than its `countdownTarget`, as `_alert_expiration` does for an assignment reminder.
More phones are reached than today, so more are offline. Losing option: relying on `stale-date`
(the activity still appears after its class began).

### D11. Removing class reminders

iOS 4.0.0:

- Removes `ClassReminderSettingsView`, `SettingsRow.classReminders`, its `SettingsPlace` entry
  and the link in `ClassTablePageSettingsView`; the three properties and their defaults in
  `LiveActivityPreferencesStore`, `AppDefaults` and `AppConstants`; the three fields and the
  `courses` section in `NotificationSettingsLocalPreferences`, `NotificationSettingsDocument`,
  `NotificationSettingsSync`, `NotificationSettingsReconcile` (no seeding) and
  `NotificationSettingsSyncer`; `.classReminderSettings` and `WhatsNewClassReminderDemo` from the
  2.4.0 list (the replay would show a removed setting); the debug "Send class reminder" kind.
  Then `check_macos_sources.py --write`, `docs/account-state.md` and ADR 0002.
- Removes the three stored defaults once with a migration in `Migrations/`. Losing option:
  leaving them (stored values no code knows, against the folder's purpose). The stored synced
  copy decodes as before, since decoding ignores the extra keys.

The `courses` section stays in each document with its values: iOS stops writing it, Android and
released iOS apps keep reading and writing it, and the backend reads it until the scan goes.
Android is not affected until its maintainer decides.

Backend, in two steps:

1. `class_reminders_skip_profile_devices` (default false): when true, the reminder scan treats an
   iPhone or iPad with a profile as no recipient, and the pipeline delivers no class reminder to
   one. It takes effect only in mode `live`, so a rollback to `shadow` brings reminders back.
2. At the owner's date (O8): delete `scan_course_reminders` and its job, `recheck_class_reminder`
   and the pipeline's `course` channel branches, `build_course_reminder_payload`, the
   `course_reminder_*` settings, the portal's `_CLASS_REMINDERS_ON` count, its status and user
   page fields and the `course` labels, and the lines in `server/AGENTS.md`, `MIGRATE.md`,
   `README.md`, `README.en.md` and `docs/push-notification-flows.drawio`. Terminal `course` jobs
   age out through `push_job_retention_days`. The shared meeting module stays.

Strings: none added or removed. `settings_class_reminder`, `settings_class_reminder_footer`,
`settings_class_reminder_lead_time`, `notification_class_preparing_title`,
`notification_class_preparing_content_fallback`, `live_activity_settings_sound_class_preparing`,
`onboarding_permissions_subtitle` and the Android channel keys stay because Android uses them.
`calendar_holiday_notify_description` is referenced by neither app today; this change leaves it.

### D12. Order

The backend deploys first at each step; see Migration Plan.

## Risks / Trade-offs

- [Apple budgets priority-10 ActivityKit pushes per hour and may throttle past it; the budget's
  size is not published] → starts keep today's count per class (at most two per meeting) and
  priority; only the number of devices reached grows; watch APNs errors per hour.
- [iOS drops a start for a device whose Live Activities were turned off in iOS Settings while the
  app has not run since] → counted as sent; the profile corrects it on the next activation; the
  owner accepted no cue for such devices.
- [The backend's timetable is stale: an edit not yet uploaded, a new term no device has uploaded]
  → served only with course sync on; the check reads current rows; `roster_requests` keeps
  enrolment fresh; a new term's classes start once a device uploads them, as reminders do today.
- [Labels differ from the device's] → shadow counts title and room differences (O1).
- [Load of the scan] → the reminder scan's query shape every 5 minutes over current-term enrolled
  courses (the reminder scan reached 505 users last week); it replaces that scan in the end.
- [The 5 s pipeline tick] → an `inClass` start goes out up to one tick after its class starts, as
  today; period boundaries put more starts in one tick; watch tick duration.
- [A served device with no token, or one APNs drops] → files nothing, counted by reason.
- [The debug clock] → server starts follow real time; a tester using the debug clock turns course
  sync off so the device falls back to its uploads.
- [Released apps lose class reminders at O8's date] → decided with the owner; see O8.

## Migration Plan

1. Backend PR 1, released as backend 4.6.0: D2's column and field, D5, D9 with the mode. Deploy
   with backup and checks; set the mode to `shadow`. Size M.
2. Shadow for the period O9 sets; fix every `app_only` and time difference. Size S per fix.
3. iOS PR: D2's report and D11's iOS part, and What's New per O4. Size M.
4. Backend PR 2, released as backend 4.7.0: D6 to D8, D10, D11 step 1. Deploy before iOS 4.0.0 is
   released and set the mode to `live`; it serves nothing until a device reports a profile. Size M.
5. iOS 4.0.0 release.
6. Parallel run per O7, then the owner sets `class_reminders_skip_profile_devices`. Size S.
7. Backend PR 3 at O8's date: D11 step 2. Size S to M.

Version numbers are as of today. Rollback: mode `shadow` stops the scan and gives class events
back to every device's upload, and D8 cancels pending server starts as `not_served`; the reminder
gate stops applying. The column stays.

Production counts to compare, counts only:

- Shadow, daily: `matched`, `app_only`, `server_only`, and differences per field.
- Live, weekly, as the 2026-11-20 measurement: users with a served device; their class meetings
  the scan filed, `classPreparing` starts with a sent delivery, and starts cancelled by reason;
  user-days with a class reminder sent and no `classPreparing` sent to a served device; iOS 4.0.0
  devices not served, by reason (in-app off, iOS off, no token, cloud or course sync off); users
  sent a class reminder who have only released apps; tick duration and starts per hour.

## Owner decisions (open)

O1. What name and room does a backend-built start show?
- (a) The stored course row (as the last uploading device showed it) and the custom name in the
  device's language. (b) The device reports its three label settings; the backend takes names
  per language from the course catalog and both abbreviation tables from one shared home, such as
  the app-translation submodule. (c) The device uploads its label per course when it changes.
- Recommendation: (a) for 4.0.0, since most accounts have one iPhone and its own upload is the
  stored row; move to (c) if shadow shows material title or room differences.

O2. What does a user who had the 10-minute banner get, and is there a sound?
- (a) The Live Activity as the device has it: `classPreparing` 60 minutes ahead by default, alert
  without sound. (b) (a) with the default sound on `classPreparing` starts, `inClass` silent.
  (c) A sound switch on the Live Activity settings (new screen copy; Android has one).
  (d) An alerting update of the running activity at the old reminder time.
- Recommendation: (b): the start is the only cue left, and Android already sounds its class Live
  Update when class reminders are off. (c) needs a UI discussion first; (d) depends on the app
  registering the activity's update token, which is not reliable.

O3. Does the class reminder lead time map to anything?
- (a) No; the stored value is dropped. (b) Once, set the class-preparing lead to the reminder
  lead for users with reminders on who never changed the Live Activity lead.
- Recommendation: (a); (b) changes a setting the user chose for the activity.

O4. What does iOS 4.0.0 say?
- (a) Two highlights in `whatsnew.json` (text below). (b) A feature page with a demo.
  (c) Nothing.
- Recommendation: (a), and remove the 2.4.0 class reminder page from the replay.

O5. What do users without a startable Live Activity get (in-app off, iOS off, no token)?
- (a) Nothing, as accepted for iOS Settings off. (b) Class reminders for those devices only.
  (c) A one-time note in the app.
- Recommendation: (a), with the reasons counted in rollout.

O6. What does a device with course sync off get?
- (a) Its uploaded schedule, today's coverage. (b) Starts from the account's timetable anyway.
  (c) Nothing.
- Recommendation: (a).

O7. When do iOS 4.0.0 devices stop getting class reminders?
- (a) At release. (b) After a two-week parallel run with both, while iOS shows no reminder
  setting (the stored on or off is still honoured). (c) iOS 4.0.0 keeps the setting; the next
  release removes it after the run.
- Recommendation: (b): coverage is measured on real devices without another app release.

O8. When does the backend stop class reminders for released apps?
- (a) A fixed date. (b) When a set share of reminder recipients report a profile. (c) With
  retiring the released versions (410 `app_version_retired`).
- Recommendation: (c): those users are told to update instead of silently losing reminders.

O9. How long does shadow run, and what passes it?
- (a) One week with no `app_only` event and no time difference after fixes. (b) Two weeks.
- Recommendation: (a).

## Proposed text (for the owner's approval)

No localization key changes. `whatsnew.json`, 4.0.0 highlights (O4 (a)):

| Key | zh-Hant | en |
| --- | --- | --- |
| whatsnew 4.0.0 highlight | 即將上課的即時動態不開 App 也會出現。 | Class Live Activities now appear without opening the app. |
| whatsnew 4.0.0 highlight | 已移除上課提醒。 | Class reminders have been removed. |
| `onboarding_permissions_subtitle` | unchanged | unchanged |

## Open Questions

- How many iPhones and iPads have course sync off, Live Activities off in the app (never sent
  today) or in iOS Settings, or no push-to-start token. The first rollout counts answer it; the
  plan does not depend on it.
