# Tasks

Backend pull requests go to tigerduck-backend `dev` and run their tests on xs-mac through the
`remote-xcodebuild` skill (`remote-pytest`); app pull requests run `remote-xcb`. Tests use
invented courses and fakes; none reach the school, Moodle, APNs or production. Each group waits
for the owner's decisions it names.

## 1. Backend PR 1: meetings, device profile, shadow comparison (backend 4.6.0)

- [ ] 1.1 Move `class_meetings`, `changed_meeting`, `PERIOD_RANK`, the schedule parsing and the
  per-day term and quiet-day rules out of `server/push/course_reminders.py` into one module that
  the reminder scan and `course_announcements/checks.py` import (design D5). Check:
  `server/tests/test_course_reminders.py` and the course announcement tests pass unchanged.
- [ ] 1.2 Replace `course_period_start_times` with `course_period_times` (start and end, the
  values of `AppConstants.PeriodTimes`) in `server/config.py`, `.env.example` and the readers.
  Check: a settings test and the reminder tests pass.
- [ ] 1.3 Add fragments, block rooms, slot ids, the course number from `course_key` and the
  `classPreparing`/`inClass` snapshot builder with `roomChanged` and `timeChanged` (D4, D5).
  Check: tests for a plain meeting, a part-cancelled one, a part room change, a moved start, a
  hand-added course with no `course_no`, each asserting the ids, times and rooms the app's
  `CourseMeeting` tests expect for the same input.
- [ ] 1.4 Add `user_devices.live_activity_profile` (migration) and its validated `live_activity`
  object on `PATCH /devices/{id}/preferences` and the response (D2), with the line in
  `docs/api-v4.md`. Check: a migration test that upgrades and downgrades, and route tests for a
  valid profile, each out-of-range field refused whole, and a PATCH without it keeping the stored
  one.
- [ ] 1.5 Add `class_live_activity_mode` and the comparison in `routes/schedule_v3.py` with its
  counter and log line (D9). Check: route tests for `matched`, `app_only`, `server_only`, a room
  difference, a device with no profile and `sync_live_activity` off, and mode `off` comparing
  nothing; the log line holds no course name or id.
- [ ] 1.6 Document the module, the profile and the mode in `server/AGENTS.md` and add the
  4.6.0 `MIGRATE.md` section. Check: the whole `server/tests` passes on xs-mac.

## 2. Backend release 4.6.0 and shadow run

- [ ] 2.1 Release and deploy with backup, start check and post-check; set
  `TIGERDUCK_CLASS_LIVE_ACTIVITY_MODE=shadow`. Check: the counter moves after an iPhone upload.
- [ ] 2.2 Run shadow for the period of O9; fix each `app_only` event and time difference in its
  own backend PR with a test that fails before the fix. Check: the counts the owner set in O9.

## 3. iOS PR: profile report and class reminder removal (iOS 4.0.0)

- [ ] 3.1 Send the profile (D2) on the device preferences request through a `SendLedger`
  channel, on `liveActivityPreferencesDidChange`, an accent change and `activityEnablementUpdates`.
  Check: unit tests that a lead change, a switch change and an authorization change each send one
  profile, an unchanged one sends nothing, and a failed send goes out on the next launch.
- [ ] 3.2 Remove the class reminder setting, properties, defaults, `courses` section handling,
  What's New page and debug push (D11), then run `check_macos_sources.py --write`. Check: the
  `NotificationSettings*` tests updated, a test that a push and a reconcile leave a document's
  `courses` section unchanged, and `check_architecture.py`, `check_account_state.py`,
  `check_comments.py check --base origin/dev`, `check_macos_sources.py` and
  `localization/check_keys.py` pass.
- [ ] 3.3 Add the migration that removes `isClassReminderEnabled`, `classReminderLeadMinutes` and
  `hasPickedClassReminderLead`. Check: a migration test with the three keys stored.
- [ ] 3.4 Add the `whatsnew.json` 4.0.0 highlights the owner approves (O4) in the version bump
  PR, and update `docs/account-state.md`, ADR 0002, ADR 0012 and
  `Devices/LiveActivity/AGENTS.md`, and write ADR 0031 for the backend-built schedule. Check:
  reviewed in the PR.
- [ ] 3.5 Run the touched suites, then the whole phone target and the macOS build on xs-mac.
  Check: the result lines in the PR.

## 4. Backend PR 2: live scan, takeover, check before sending (backend 4.7.0)

- [ ] 4.1 Add the served-device function (D3) and the scan job (D7) with its two settings,
  registered only in mode `live`. Check: tests for a served device filing both scenarios, each
  unserved reason filing nothing, a scenario off, a lead change moving a pending job, a passed
  lead firing now, a hidden course and a cancelled class cancelling the pending job, and a
  pending uploaded job taken over under its key.
- [ ] 4.2 In `routes/schedule_v3.py`, drop class events from served devices after the comparison
  and limit their sweep to `assignmentUrgent` (D6). Check: tests that an upload missing a day
  keeps the server's starts, that an unserved device's upload behaves as on `dev`, and that no
  key ever has two pending jobs.
- [ ] 4.3 Add the check before a server-filed start (D8) and strip `filed_by` and
  `user_course_id` in `job_payloads.py`. Check: pipeline tests for each cancel code, a failing
  query cancelling as `unverified_before_send`, and an app-filed start keeping today's checks.
- [ ] 4.4 Expire a class start at its `countdownTarget` (D10), and add the sound if the owner
  chose O2 (b). Check: payload tests.
- [ ] 4.5 Add `class_reminders_skip_profile_devices` (D11 step 1) to the scan and the pipeline.
  Check: tests that with it on and mode `live` a profile device gets no reminder and a released
  app still does, and that mode `shadow` ignores it.
- [ ] 4.6 Update `server/AGENTS.md` (schedule channel, class starts), `docs/api-v4.md` (who
  changes a device's pending starts), `docs/push-notification-flows.drawio` and the 4.7.0
  `MIGRATE.md` section. Check: the whole `server/tests` passes on xs-mac.

## 5. Releases

- [ ] 5.1 Release and deploy backend 4.7.0 before iOS 4.0.0 goes out and set the mode to
  `live`. Check: the post-check passes and no `filed_by` job exists until a device reports a
  profile.
- [ ] 5.2 Release iOS 4.0.0 (`release-bump`). Check: TestFlight devices report a profile and
  receive server-filed starts.
- [ ] 5.3 Run the parallel period of O7 and report the weekly counts of the Migration Plan; the
  owner then sets `class_reminders_skip_profile_devices=true`. Check: the counts and the owner's
  go-ahead.

## 6. Backend PR 3: remove class reminders (at the date of O8)

- [ ] 6.1 Delete the reminder scan and its job, `recheck_class_reminder`, the `course` channel
  branches, `build_course_reminder_payload` and the `course_reminder_*` settings (D11 step 2),
  keeping the meeting module. Check: the remaining tests pass and `rg course_reminder server`
  finds only migrations and the changelog.
- [ ] 6.2 Remove the portal's class reminder count, its user page field and the `course` labels.
  Check: portal tests, including `test_audit_coverage.py`, and the web build pass.
- [ ] 6.3 Update `server/AGENTS.md`, `MIGRATE.md`, `README.md`, `README.en.md` and the flows
  drawing. Check: the whole `server/tests` passes on xs-mac; release and deploy.

## 7. Android (its maintainer)

- [ ] 7.1 Decide whether Android keeps its local class reminders and the `courses` section; this
  change needs nothing from Android. Check: the maintainer's answer.

## Workflow follow-up

- Archive the change after the last pull request merges:
  `openspec archive server-scheduled-class-live-activities`.
