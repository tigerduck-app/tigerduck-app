# Proposal

## Why

A student learns that a class is an exam, or that it moved online, only by opening the course: today
both are stored as a `note`, which the class table shows as a small bubble and the widgets, Home and
Live Activity do not show at all. Of the term's 22 notes, 10 are assessments (midterms, a final,
two whole-class presentations) and 2 move a whole class online. The owner wants assessments marked
where a class is drawn, and the note kept as the last resort for what fits no other kind.

## What Changes

- Two course change kinds join `cancelled`, `room`, `start`, `end` and `note`:
  - `assessment` (評量): every student of the course is assessed in that class meeting, at the same
    time. It carries a required name in Chinese and English, such as 期中考 / Midterm exam.
  - `online` (線上): the class meeting is held online instead of in its room. It carries an optional
    description.
- The course change feed sends the new kinds only to a client that says it understands them. Any
  other client (iOS 4.0.2 and earlier, Android) gets each one as a `note` with the same text, so it
  loses nothing it shows today.
- A one-time backend migration converts the term's existing notes by id: 10 to `assessment` (期中考 ×7,
  期末考, 期中分組簡報, and 期末報告 renamed 期末簡報) and 2 to `online`. The other 10 stay notes.
- The portal's change dialog gains both kinds. Assessment presets: 期中考, 期末考, 小考, 期中簡報,
  期末簡報, each with its English name; the note keeps 補課.
- Course announcement extraction: an exam with a date on one of the course's class days becomes a
  pending `assessment` review item, and a class moved online a pending `online` one. Presentations
  stay manual.
- Pushes: a class reminder for an assessment begins with its name (期中考 · 09:10 · IB-101); an online
  class shows 線上 / Online where the room was, in reminders and Live Activity starts; a Live Activity
  start carries whether the class is an assessment.
- The Apple apps draw an assessment as a muted red dashed underline under the course name, on that
  day's class only, in the class table (iPhone, iPad, Mac), Home's course cards and time machine, the
  widgets, the Mac widget cards and the Live Activity, and VoiceOver reads 評量 / Assessment after the
  course name. An online class shows 線上 / Online in place of its room on those surfaces and on the
  Watch. The course sheet lists 評量 · <name> and 線上 · <description>.
- A `GLOSSARY.md` at the app repository's root and new entries in the backend's define course
  change, assessment, term exam, presentation, online class and note.
- ADR 0031 records why the feed decides per client which kinds it sends.

Out of scope:

- Android. It keeps receiving notes; an issue tracks the new kinds there.
- The underline on the Watch; the Watch only gets the online room.
- A presentation split over several weeks: it stays a note, since the app cannot know which week is
  the user's.
- Online quizzes, take-home exams and hand-in deadlines: not class meetings, so not assessments.
- Extracting presentations from course announcements, and any classifier retraining.
- Exams with no date or off a class day: they stay information in the portal.
- New settings, a filter for assessments, or any notification of its own for an assessment.
- The server-built class Live Activities of `server-scheduled-class-live-activities` (#1021); that
  change reuses the shared meeting rules this one extends.

## Capabilities

### New Capabilities

- `course-changes`: the kinds of course change, what each carries, how the feed serves them to new
  and old clients, how the portal and the course announcement extraction write them, and how class
  pushes apply them.
- `course-change-display`: how the Apple apps show assessments and online classes on every surface
  that draws a day's class.

### Modified Capabilities

None.

## Impact

- tigerduck-backend: `server/academic_calendar/models.py` (kind and per-kind checks, the clash rule)
  and an Alembic migration with the data conversion; `server/academic_calendar/changes.py`,
  `schemas.py` and `server/routes/academic_calendar.py` (the `kinds` parameter, the ETag, the note
  fallback); `server/push/course_reminders.py`, `server/push/class_starts.py` and the per-device
  copy in `server/push/notification_copy.py` / `pipeline.py`; `server/course_announcements/`
  (`extraction.py`, `items.py`, `checks.py`, `apply.py`); `portal/app/routes/course_changes.py` and
  `portal/web/src/pages/course-changes/`; `docs/api-v4.md`, `MIGRATE.md`, `GLOSSARY.md`; the
  `app-translation` pin.
- app-translation: keys `course_change_assessment` and `course_change_online` in every locale, in
  the shared bundle the backend reads too.
- iOS / macOS / watchOS: `School/Calendar/CourseChanges.swift`, `Models/Domain/CourseTimeSlot.swift`
  and `CourseMeeting.swift`; the class table cells, menu and course sheet; Home's `CourseTimeCard`
  and the time slider; `Devices/Widgets/WidgetSnapshot*.swift` and `TigerDuckWidgets/Views/`;
  `Platform/Mac/MacWidgetCards.swift`; the Live Activity attributes, resolver and views;
  `Devices/Watch/WatchPayloadEncoder.swift`; a new color in `Color+Extensions.swift` and
  `WidgetPalette.swift`.
- `tigerduck-android`: unchanged; an issue and a note to its maintainer.
