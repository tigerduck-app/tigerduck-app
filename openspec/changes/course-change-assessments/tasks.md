# Tasks

## 1. Plan (tigerduck-app, docs pull request to dev)

- [ ] 1.1 Add this change, ADR 0031 (`docs/decisions/0031-course-change-kinds-by-client.md`) and the
  root `GLOSSARY.md`; verify with `openspec validate course-change-assessments --strict` and the
  `comments` check on the pull request

## 2. Strings (app-translation pull request)

- [ ] 2.1 Add `course_change_assessment` (評量 / Assessment) and `course_change_online` (線上 / Online)
  to the shared strings in every locale, following the `translation-change` skill; verify with the
  repository's own check and that the generated backend bundles for `zh-Hant` and `en` hold both keys

## 3. Backend (tigerduck-backend pull request to dev, then a release)

- [ ] 3.1 Migration: add `assessment` and `online` to `chk_course_change_kind`, give each kind its
  value checks (assessment: both names non-blank; online: no room, optional texts), let `note_zh` /
  `note_en` be set for `note`, `assessment` and `online` only, and convert the 12 rows of the spec by
  id with the text guard; verify with a migration test that upgrades and downgrades a database seeded
  with those ids and one with other rows at those ids
- [ ] 3.2 Clash rule: `room` and `online` clash with each other, `assessment` with `assessment` only;
  verify with tests of the shared rule function through the portal and the automatic writer
- [ ] 3.3 Feed: the `kinds` parameter, the note fallback (names; description or the
  `course_change_online` strings) and the ETag over the listed kinds; verify with route tests for no
  `kinds`, both kinds, an unknown value, and a 304 that turns into a 200 when `kinds` is added
- [ ] 3.4 Pushes: `meeting_changes` returns assessments and online changes; the class reminder body
  begins with the assessment's name and shows `course_change_online` for the room, resolved per device
  locale at send time; the Live Activity start sets `locationText`, `roomChanged` and `assessment`;
  verify with reminder and class start tests in Chinese and English
- [ ] 3.5 Portal: kinds, presets (assessment: 期中考, 期末考, 小考, 期中簡報, 期末簡報 with English;
  note: 補課), the online description, the table, term strip and announcement detail; verify with the
  portal route tests and `npm run build` / the portal's lint in `portal/web`
- [ ] 3.6 Extraction: exams with a class-day date become pending `assessment` items named by exam
  kind, online moves become `online` items, the labels check takes an exam label for an assessment,
  and an empty English name blocks automatic apply; verify with extraction, items and checks tests
- [ ] 3.7 Docs: `docs/api-v4.md` (the parameter, kinds, what `note_*` hold per kind), `MIGRATE.md`,
  `server/AGENTS.md` where it lists kinds, and the backend `GLOSSARY.md`; bump the `app-translation`
  pin to the strings merge; verify with the full backend test suite on xs-mac and CI
- [ ] 3.8 Before the deploy, send the owner the 12 rows the migration converts and their new kinds
  and names; deploy only on their word, then confirm in production, read-only, that 10 assessments
  and 2 online changes exist and that a request without `kinds` still returns 22 notes

## 4. App: model, class table, course sheet, Home (tigerduck-app pull request to dev)

- [ ] 4.1 `CourseChange.Kind` gains `assessment` and `online`, the request sends
  `kinds=assessment,online`, and `CourseTimeSlot` exposes the day's assessment and whether it is
  online; verify with `CourseChangesTests` (decode, fallback rows, unknown kind) and
  `TimeSliderViewModelTests`
- [ ] 4.2 Add `assessmentInk` (light and dark) and the dashed underline to the class table cell,
  Home's `CourseTimeCard` and the time machine; online shows `course_change_online` as a room change;
  an assessment adds no note bubble; verify with the hosted-view tests of those views and screenshots
  on iPhone (375 pt and a long course name), iPad and Mac, in light and dark
- [ ] 4.3 Course sheet rows `評量 · <name>` and `線上 · <description>`, and VoiceOver labels; verify
  with the course sheet and accessibility label tests
- [ ] 4.4 Send the screenshots to the owner and set the color they choose; merge only after that

## 5. App: widgets, Mac cards, Live Activity, Watch (tigerduck-app pull request to dev)

- [ ] 5.1 `SnapshotCourseChange` carries the assessment flag and the online room; the widget views
  underline and show 線上; verify with `WidgetSnapshotBuilderTests` and widget view tests
- [ ] 5.2 `MacWidgetCards` underlines and shows 線上 with the change color; verify with the mac build
  and a Mac card test
- [ ] 5.3 `LiveActivitySnapshot.assessment`, set by `LiveActivityScenarioResolver` and drawn by the
  Live Activity views; online sets `locationText` and `roomChanged`; verify with resolver tests and a
  decode test of a backend payload with and without the new key
- [ ] 5.4 `WatchPayloadEncoder` sends an online meeting as a room change named 線上 / Online; verify
  with `WatchPayloadEncoderTests`

## 6. Android

- [ ] 6.1 File the Android issue for the two kinds (`kinds` parameter, underline, online room) and
  tell its maintainer's agent over agent-tunnel; verify the issue URL is in HANDOVER.md

## Workflow follow-up

- Archive with `openspec archive course-change-assessments` after the last pull request merges.
- If #1021 merges first, move task 3.4's meeting rule into its shared module; otherwise add the
  assessment flag and the online location to #1021's spec before it is implemented.
