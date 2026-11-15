# Proposal

## Why

Teachers announce class cancellations, room moves and exam dates in Moodle course announcements,
and today those reach `course_changes` (and so the apps' timetables and class reminders) only when
an operator types them into the portal by hand. A classifier that labels Moodle course announcements
now exists (`tigerduck-app/announcement-classifier`, release `model-2026-11-15`), so the backend can
find these announcements itself, extract the facts and either apply them or queue them for an
operator.

## What Changes

- The classifier runs as a host service next to the existing local LLM server, with its launchd plist
  in the backend's `deploy/launchd/` and a check in the post-boot script.
- `moodle_assignments` runs keep each user's enrolled Moodle courses, which they already fetch, so
  the backend knows every course a TigerDuck user is in.
- The backend polls the news forum of every current-term course with an eligible holder (an enrolled
  user with an active Moodle credential and a device the sync worker serves), on its own request
  budget and metric, at an interval set by how recently the course last posted, and only while
  Moodle traffic is allowed.
- Each new or edited course announcement is stored, classified, and sent to the local LLM when an
  exam or class label is uncertain or a fact-bearing label is confident. The LLM returns structured
  course changes, held-as-usual dates, make-up classes and exams with verbatim evidence.
- Extractions become review items per course code that add, replace or remove a change. Machine
  checks (evidence, term, class day, stated weekday, the `course_changes` rules including clashes,
  label agreement, the LLM's certainty, whole-course visibility) decide whether an add item may apply.
  Until the owner enables automatic apply, every item waits for review (shadow mode); replace and
  remove items always do.
- The portal's `course_changes` clash and meeting rules move into a database function that the portal
  and the automatic writer share.
- `course_changes` gains a nullable `source_announcement_id`; automatic writes use the actor
  `course-announcements` and are audited.
- The portal gains a Course announcements page: a review queue with one row per item (approve, edit
  and approve, reject), the term's announcement list, and a detail panel with the text, classifier
  scores, checks and extracted facts.
- A one-time import loads the full announcement history from a local export, without author names,
  through the same ingest path; current-term announcements that meet the LLM rule are extracted,
  and facts whose dates have all passed are recorded as past rather than queued.
- `OpenAICompatibleProvider`'s HTTP, schema and retry handling is extracted so bulletins and course
  announcements share one client.
- A `GLOSSARY.md` in the backend repository defines course announcement, extraction and pending
  review.

Out of scope: class-cancellation pushes, an exam table and any app screen for exams, a
`course_changes` form for make-up classes, detecting deleted announcements, a `/v4` course
announcement API, cheaper Moodle change detection (for example `numdiscussions`), replacing the LLM
model (benchmarked separately; the model stays a setting), and retraining the classifier.

## Capabilities

### New Capabilities

- `course-announcements`: how the backend collects Moodle course announcements, classifies them,
  extracts course changes and exams, decides what may change `course_changes`, and what operators
  see and decide in the portal.

### Modified Capabilities

None. `course_changes` keeps its rules; this change adds a writer and a source column.

## Impact

- tigerduck-backend `server/`: a new `course_announcements` package (poller, ingest, routing,
  extraction, checks, items, apply), new tables and migrations, a new APScheduler job, settings for
  the classifier URL, the poll budget and automatic apply, a request observer on `RequestBudget`, the
  enrolled-course list in `moodle_assignments` runs, and a shared LLM client under
  `server/bulletins/llm/` that keeps text out of errors and logs.
- tigerduck-backend `portal/`: the course-changes checks call the shared database function; a new
  route module and page, NAV entry and types; review writes reuse the course-changes write path and
  its audit.
- tigerduck-app/announcement-classifier: `/health` reports the model release.
- tigerduck-backend `deploy/launchd/` and its README; the xs-mac post-boot check (local tool).
- Moodle traffic: up to 20 more requests a minute, outside 00:00 to 05:00 Taipei.
- The local LLM server: course announcement extraction queues behind bulletin processing.
- Production data: course announcement texts (which may name students) stored indefinitely and
  shown only in the portal.
- No app change; the apps already read `course_changes` through `/v4/calendar/course-changes`.
