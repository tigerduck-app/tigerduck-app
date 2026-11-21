# Design

## Context

- `course_changes` (tigerduck-backend `server/academic_calendar/models.py`) holds one row per
  change with a `kind` among `cancelled`, `room`, `start`, `end`, `note`, a check constraint per
  kind, and `note_zh` / `note_en`. Operators write it in the portal; the course announcement
  pipeline writes it through review items. The clash rules live in one database function the portal
  and the automatic writer share.
- `GET /calendar/course-changes` is public and cached (`Cache-Control: public, max-age=300`, weak
  ETag over each row's id, edit time and class days). iOS 4.0.2 and earlier drop a row whose kind
  they do not know (`CourseChange(row:)` returns nil), and so does nothing on Android yet.
- Class reminders (`push/course_reminders.py`) and class Live Activity starts
  (`push/class_starts.py`) apply `cancelled`, `start`, `end` and `room` at send time through
  `meeting_changes`, which skips notes. The reminder body is `HH:mm · room`, the same in every
  language; Live Activity starts are filed by the app and rewritten by the backend before sending.
- The app shows changes only for this week's date of each weekday on the class table, and on Home,
  the widgets, the Mac cards, the Watch and the Live Activity through `CourseTimeSlot`. Changes use
  `changeInk` (#7C2D12 / #FDBA74). The widgets and the Watch carry no notes at all.
- The in-flight change `server-scheduled-class-live-activities` (#1021, draft) moves the meeting
  rules out of `push/course_reminders.py` into a shared module and later removes iOS class
  reminders.

## Goals / Non-Goals

**Goals:**

- One meaning per kind, so every surface can draw an assessment and an online class without parsing
  free text.
- Nothing a released app shows today disappears.
- The backend ships and deploys first; the app follows in two pull requests.

**Non-Goals:**

- A typed exam model (seats, scope, time other than the class's). An assessment marks a class
  meeting; its name is the only detail.
- Changing the note. It stays for what fits no kind.

## Decisions

### 1. Two kinds, not a flag on the note

`assessment` and `online` are kinds with their own constraints.

- Lost: a boolean `is_assessment` on notes. Every reader would test kind and flag, an online class
  would need a second flag, and the owner wants the note to remain the last resort, not the carrier
  of meaning.
- Lost: an `exam_type` subtype (midterm, final, quiz, presentation). Nothing draws them differently,
  and the name already says which it is.

### 2. The feed serves kinds by what the client says it reads (ADR 0031)

The app sends `kinds=assessment,online`; any other request gets the new kinds as notes with the
same text. The ETag hashes the listed kinds.

- Lost: sending the new kinds to everyone. iOS 4.0.2 and Android would drop those rows, losing the
  exam notes they show today.
- Lost: guessing from `User-Agent` or the app version. The endpoint is public and unauthenticated,
  version strings differ between platforms, and a guess fails silently.
- Lost: a new endpoint or API version. One field's vocabulary does not justify a second route, and
  `/v4` already serves both apps.
- Without the ETag change, an app upgraded from 4.0.2 would send its stored ETag, get 304 and keep
  its notes until the term's data next changed.

### 3. Reuse `note_zh` / `note_en` for the name and the description

An assessment's name and an online change's description live in `note_zh` / `note_en`, and the feed
keeps those field names; the schema documents what they hold per kind.

- Lost: new `name_*` and `description_*` columns. They would double the per-kind constraints and the
  portal's fields for the same two strings, and the fallback to a note would copy them back anyway.
- The column names then read "note" for an assessment. The model's docstring and `docs/api-v4.md`
  say so.

### 4. Clash rules

Same kind clashes as today, notes never clash, and `room` and `online` clash with each other, since
both say where the meeting is held. An assessment does not clash with other kinds: an exam can move
room or start earlier.

- Lost: letting room and online coexist and picking one. A rule the operator sees beats a silent
  precedence.

### 5. Push copy per device

The class reminder body and the Live Activity's location become language-dependent for these two
kinds, so they are resolved per delivery from the device's `locale`, as assignment reminder copy
already is (`push/notification_copy.py`). The job payload carries only the assessment's two names
and whether the meeting is online. The Live Activity start also sets `roomChanged` for `room` and
`online`, which the app's own snapshots already set, and a new optional `assessment` flag.

- Lost: one language for every device. The name and 線上 / Online are words, not numbers.

### 6. Strings in the shared bundle

`course_change_assessment` and `course_change_online` go to app-translation's shared strings, so
the apps and the backend (the online fallback note and the push copy) read the same words.

### 7. Muted red dashed underline

A new color, `assessmentInk`, in `Color+Extensions.swift` and `WidgetPalette.swift`, starting at
#B4534B in light and #E39A92 in dark, drawn with `Text.underline(_:pattern:color:)` and the `.dash`
pattern. The owner confirms the color from screenshots of the class table, a widget and a Live
Activity before the first app pull request merges.

- Lost: `changeInk` (orange-brown): it already means a changed room or time.
- Lost: system red: too saturated for the owner.
- Lost: a badge or text label: the owner asked for an underline and no extra text.

### 8. Watch: online only, by the room it already shows

The phone's `WatchPayloadEncoder` sends an online meeting as a room change whose room is 線上 /
Online in the phone's language. The Watch app and its payload format do not change, and the Watch
draws no underline.

### 9. Extraction maps exam kinds to the presets

`midterm`, `final` and `quiz` exams become the presets' names; `other` keeps the extracted Chinese
name and an empty English name that blocks automatic apply until an operator fills it. The labels
check asks for `exam_info` or `exam_change` instead of `class_change` for an assessment. Presentations
have no label or schema field, so they stay manual.

### 10. Converting the notes in the migration

The Alembic migration that changes the constraints converts the 12 rows by id, each only while its
kind and Chinese text still match, and its downgrade restores them. It deploys with the code and is
reversible.

- Lost: SQL run by hand on production: no review and no rollback.
- Lost: converting by matching text (`note_zh = '期中考'`): a future note of another meaning could
  match, and the multi-week presentations must stay notes.

### 11. The order with #1021

This change extends `meeting_changes` / `changed_meeting` where they are on `dev` when it starts.
If #1021 lands first, the extension goes into its shared module; if this one lands first, #1021's
builder of class starts must carry the assessment flag and the online location, and its spec gains
that line.

## Risks / Trade-offs

- [An old client behind a shared cache gets a response meant for a new one] → The kinds are in the
  query string, which is part of every cache key, and in the ETag.
- [An automatic assessment is wrong and underlines a normal class] → Automatic apply stays off
  (shadow mode) until the owner turns it on, needs an exam label from both models, and an operator can
  delete the change.
- [Online and room clash blocks a legitimate pair] → None known: a class held online has no room.
- [The underline is lost on a long course name that wraps or truncates] → The underline is drawn on
  each line; on truncated names it covers the visible part, which is still the course name.
- [Android users see exams as notes until Android adopts the kinds] → An issue and a note to its
  maintainer.

## Migration Plan

1. app-translation: the two keys.
2. Backend: the code and the migration on `dev`, then a release. Before the deploy, list the 12 rows
   to be converted to the owner; deploy on their word. Released apps keep working: they send no
   `kinds` and get notes.
3. App pull request 1, then 2; both ship in the next iOS release.
4. Rollback: downgrade the migration, which turns every assessment and online row, the converted
   ones and any added since, into notes, and redeploy the previous backend. The new app then receives
   notes again (FastAPI ignores the unknown `kinds` parameter) and shows them as before.

## Open Questions

- The exact assessment color, settled from the screenshots before the first app pull request merges.
