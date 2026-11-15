# Tasks

All code pull requests go to tigerduck-backend `dev`. Backend tests run on xs-mac through the
`remote-xcodebuild` skill (`uv run pytest ...`, Postgres required). Tests use fake Moodle, classifier
and LLM clients and invented announcement text; none reach the school, Moodle or a real service.

## 1. PR: shared JSON-schema LLM client and glossary

- [ ] 1.1 Move the HTTP, caller-given `json_schema` response format, retry and backoff code of
  `server/bulletins/llm/openai_compat.py::OpenAICompatibleProvider` into a client that returns parsed
  JSON, and rebuild the bulletin provider on it with its prompt and `BulletinMetadata` parsing
  unchanged. Check: the existing bulletin LLM tests pass unchanged
  (`uv run pytest server/tests -k "bulletin and llm"`).
- [ ] 1.2 Test the client with a fake transport: the given schema reaches the request, invalid JSON is
  retried twice with backoff, then raises. Check: the new test passes.
- [ ] 1.3 Add `GLOSSARY.md` at the backend root defining course announcement, extraction and pending
  review (design D11). Check: reviewed in the PR.

## 2. PR: classifier service, storage, polling and classification

- [ ] 2.1 Add `deploy/launchd/ai.tigerduck.classifier.plist` (from the classifier repo) and a section
  in `deploy/launchd/README.md` on installing it with `deploy/install.sh <tag>`. Check:
  `plutil -lint deploy/launchd/ai.tigerduck.classifier.plist`.
- [ ] 2.2 Add settings `announcement_classifier_url` (unset disables the feature),
  `course_announcement_requests_per_minute` (20) and `course_announcements_auto_apply` (false) to
  `server/config.py`, `.env.example` and `server/AGENTS.md`. Check: a settings test reads each from
  the environment.
- [ ] 2.3 Add the models and one Alembic migration for `course_announcements`,
  `course_announcement_extractions`, `course_announcement_facts`, the per-course poll state and
  `course_changes.source_announcement_id` (design D5), imported in `env.py` and
  `test_migrations_metadata.py`. Check: `uv run pytest server/tests/test_migrations_metadata.py` and
  the migration upgrade/downgrade test.
- [ ] 2.4 Add `mod_forum_get_forums_by_courses` (many course ids per call) and
  `mod_forum_get_forum_discussions` (`page=0`, explicit `perpage`) to the Moodle client the way
  `HttpCourseFetcher` calls `_checked_call`, on a client that carries its own `RequestBudget` from
  `course_announcement_requests_per_minute`. Confirm the discussions call's default sort from the
  Moodle source and record it in a comment with the source link. Check: fake-transport tests for both
  calls, token scrubbing in errors, and a rate-limit pause that leaves the sync budget unpaused.
- [ ] 2.5 Add the classifier client (`POST /v1/classify`, batches of up to 64 posts) and a recording
  fake. Check: tests for a batch, a 400, and the service being unreachable.
- [ ] 2.6 Build the poll state: current-term courses from `user_courses` with Moodle course ids from
  `user_assignments` and `user_course_overrides`, token holders via `load_moodle_token`, the recency
  tiers, most-overdue-first selection within the budget, the 00:00 to 05:00 Taipei pause, and moving
  to the next token holder after `mark_credentials_invalid`. Check: tests for each tier boundary
  (7 and 14 days, never posted), the pause window, selection order and token fallback.
- [ ] 2.7 Build ingest: store new announcements and replace edited ones (by `modified`), course codes
  of merged sections (reuse the backend's existing course-number parsing if one exists), no author
  fields, classification or `unclassified` when the service is down, and the LLM route rule from the
  spec. Check: tests for new, edited, unchanged, merged sections, classifier down, and the route rule
  at 0.10, 0.90 and a confident fact label.
- [ ] 2.8 Register the poll job in `build_scheduler` only when `announcement_classifier_url` is set.
  Check: a scheduler test with and without the setting.

## 3. PR: extraction, checks and apply

- [ ] 3.1 Add the extraction prompt and schema (the benchmarked rules and schema, kept next to the
  code) on the client from 1.1, storing the model name and raw output. Check: tests with a fake LLM
  for a cancellation, a room change, an exam and an invalid answer.
- [ ] 3.2 Add the extraction job: every minute, only while no bulletin is pending; retries on up to 3
  later cycles with growing intervals, then `failed`; operator-queued re-extraction; a new version
  supersedes the old extraction and its facts. Check: tests for bulletin-first ordering, the retry
  schedule, failure and supersede.
- [ ] 3.3 Add the checks of design D7 per course code: evidence verbatim, term bounds, class day via
  `course_class_days`, stated weekday, `course_changes` rules, label agreement, certainty, no existing
  change of that kind on that day. Check: one test per check, plus merged sections where one code
  fails.
- [ ] 3.4 Add apply: facts become `pending` with the passes-all-checks mark in shadow mode; with
  `course_announcements_auto_apply` a passing course change is written for each course code with the
  source id and actor `course-announcements`; an edit of an applied announcement queues every new
  fact; facts whose dates have all passed become `past`; make-up classes and exams become `info`.
  Check: tests for shadow mode, auto apply, edit after apply, past and info.
- [ ] 3.5 Keep `/v4/calendar/course-changes` responses unchanged by the new column. Check: the
  existing calendar API tests pass and a test asserts the response fields.

## 4. PR: portal Course announcements page

- [ ] 4.1 Add `portal/app/routes/course_announcements.py` mounted in `main.py`: term announcements
  (search, extraction filter, pagination), one announcement's detail, the review list, approve
  (through the course-changes parse, check, insert and `audit(...)` code), reject with an optional
  reason, and queue re-extraction, each write audited. Check: route tests and
  `portal/tests/test_audit_coverage.py`.
- [ ] 4.2 Let the course-changes create call carry an optional fact id that sets the source id and
  marks the fact approved, for edit-and-approve. Check: a route test that creates through the dialog
  path and finds the fact approved.
- [ ] 4.3 Build `portal/web/src/pages/course-announcements.tsx` from the approved mock with the NAV
  entry (Moodle group), route in `App.tsx` and types in `types/api.ts`; announcement text uses the
  `pii` reveal; edit-and-approve opens the existing change dialog prefilled. Check: the portal web
  build, type check and lint pass, and headless Chromium screenshots at desktop and 375 px with long
  subjects and three-digit counts show no overflow.

## 5. PR: history import

- [ ] 5.1 Add a backend command that reads an export JSONL, rejects any record with author fields,
  classifies in batches of 64, stores through the ingest path idempotently, and queues extraction for
  current-term announcements the route rule selects. Check: tests with an invented export, including
  a second run that stores nothing new.
- [ ] 5.2 Add the export script that writes that JSONL from the local announcement dump to the private
  `tigerduck-app/announcement-classifier-data` repository. Check: run it locally and confirm with a
  key scan that no record has an author field.

## 6. Release and rollout (owner's go-ahead at each step)

- [ ] 6.1 Install the classifier on xs-mac with `deploy/install.sh model-2026-11-15`, load the plist,
  and add port 40002 to the post-boot check. Check: `curl localhost:40002/health` on the host and the
  same URL through `host.docker.internal` from the backend container.
- [ ] 6.2 Release the backend with a `MIGRATE.md` section and deploy it with the classifier URL set.
  Check: the post-deploy check passes, logs show poll ticks, and the course announcement request
  rate stays at or below 20 a minute.
- [ ] 6.3 Run the history import. Check: read-only counts of stored announcements and queued
  extractions in production.
- [ ] 6.4 After two weeks in shadow mode, review the would-apply facts against operator decisions and
  let the owner decide on `course_announcements_auto_apply`. Check: the owner's decision recorded in
  the PR or issue that flips it.

## Workflow follow-up

- Archive with `openspec archive course-announcements` after the last pull request merges.
