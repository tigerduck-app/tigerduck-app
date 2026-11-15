# Design

## Context

See proposal.md for why. The facts below are from tigerduck-backend `origin/dev` at 1a5a42f
(backend 4.3.0).

- `server/scheduler/runtime.py::build_scheduler` runs global APScheduler jobs in the single uvicorn
  process (`max_instances=1`, coalesce). Bulletins use two of them: `bulletin_scrape` and
  `bulletin_process`, the latter draining pending rows through the LLM every 60 s.
- `server/syncjobs/budget.py::RequestBudget(per_minute)` spaces requests and pauses on
  `MoodleRateLimited`. `server/main.py` builds one instance from `sync_job_requests_per_minute`
  (10) and attaches it to the Moodle client as an httpx event hook.
- `server/syncjobs/moodle_client.py::_checked_call` maps Moodle errors to `MoodleTokenInvalid`,
  `MoodleRateLimited` and `MoodleUnreachable`; `HttpCourseFetcher` is the pattern for a new
  wsfunction. `server/syncjobs/credentials.py::load_moodle_token` and `mark_credentials_invalid` read
  and retire a user's Moodle token.
- `server/bulletins/llm/openai_compat.py::OpenAICompatibleProvider` owns httpx, strict
  `json_schema` response format, 2 retries with backoff, temperature 0.2, but returns
  `BulletinMetadata` only. `settings.llm_base_url` and `settings.llm_model` point at the local
  llama-server (gemma-4-E4B, one slot).
- `course_changes` (`server/academic_calendar/models.py::CourseChange`) holds one exception per row
  with check constraints per kind; `course_class_days` / `course_meetings` in the database compute a
  course's class days from `user_courses.schedule_json` and holidays. The portal writes it through
  `portal/app/routes/course_changes.py` (`_parse`, `_check`, insert, `audit(...)`).
- The portal reads and writes Postgres directly with asyncpg (`get_pool`); every write route must call
  `audit(...)` (`portal/tests/test_audit_coverage.py`). Personal-data columns use the DataTable `pii`
  reveal, reset to hidden on load.
- The classifier service (`tigerduck-app/announcement-classifier`, `scripts/serve.py`) answers
  `POST /v1/classify` with `{"posts": [{"subject", "message"}]}` (1 to 64), returning labels at the
  0.35 threshold, 20 scores and the converted Markdown `text`. It has no authentication and is meant
  to be reached from the backend container at `host.docker.internal:40002`, like the LLM.

## Goals / Non-Goals

**Goals:**

- One ingest path for polled and imported announcements: store, classify, route, extract, check,
  then apply or queue.
- Nothing reaches `course_changes` without passing the checks, and nothing at all automatically until
  an operator turns automatic apply on.
- Every polled request counts against a budget of its own; sync jobs keep theirs.

**Non-Goals:**

- Choosing the LLM model. It stays `settings.llm_model`; a benchmark of replacements runs outside this
  change, and a swap only needs a re-extract run.
- Reading attachments or discussion replies.

## Decisions

### D1. The classifier is a separate host service called over HTTP

The backend calls `TIGERDUCK_ANNOUNCEMENT_CLASSIFIER_URL` (default unset, which disables the feature).
Losing options: loading the model inside the backend container would add torch and a 1.1 GB model to
the image and to every backend restart; a Docker sidecar would also carry the 1.1 GB image. The host
service matches how the LLM already runs, can be redeployed from the public release with
`deploy/install.sh <tag>`, and tests use a fake client like `RecordingProvider`.

### D2. One global poll job with a per-course due time in the database

A table of poll state per `(term_code, moodle_course_id)` holds the news forum id, the latest post
time, `next_due_at` and the token holder last used. A job every minute (skipped 00:00 to 05:00 Taipei)
selects the courses with the oldest `next_due_at` in the past, as many as the budget allows, polls
them, and sets `next_due_at` from the latest post time with the tiers in the spec. The course list
comes from current-term `user_courses` joined to the Moodle course ids in `user_assignments` and
`user_course_overrides`. Losing options: a `sync_jobs` type per user (each course would be polled once
per enrolled user, and `job_type`'s CHECK needs a migration anyway); a fixed round robin (the owner
chose posting-recency tiers); in-memory schedules (lost on restart, and the single process makes the
database cheap enough).

### D3. A second `RequestBudget` at 20 requests a minute

`course_announcement_requests_per_minute` (default 20) builds its own `RequestBudget` on the client
the poller uses, so a rate-limit pause from either side pauses only that side. From the current term's
posting pattern the tiers average 11 to 17 requests a minute between 05:00 and 24:00. Losing options:
sharing the sync budget (a full pass would occupy it for over an hour and stall assignment sync); no
budget (Moodle traffic must stay bounded).

### D4. Moodle calls

Per term, `mod_forum_get_forums_by_courses` with many `courseids[n]` per request finds each course's
`type == "news"` forum, cached in the poll state. Each poll is one `mod_forum_get_forum_discussions`
call with `page=0` and a small `perpage` (Moodle's default 0 returns the whole forum), whose default
order is latest activity first, so new posts and recent edits are on the first page. Losing option:
reading every page each time (cost grows with the forum, for the rare edit of an old post). Edits and
deletions beyond the first page are not seen; deletion is out of scope.

### D5. Storage

New tables, enum-like columns as String plus CHECK, times as timestamptz, imported in `env.py` and in
`test_migrations_metadata.py`:

- `course_announcements`: id `"{discussion}-{post}"`, term code, Moodle course id, course codes
  (array), subject, converted text, posted and modified times, attachment flag, classifier release,
  scores (jsonb), labels (array), route (`unclassified`, `not_sent`, `sent`).
- `course_announcement_extractions`: one per announcement version sent to the LLM: the version's
  `modified` time, model, raw output (jsonb), certain, status (`queued`, `done`, `failed`), attempts,
  next attempt time, error, superseded time.
- `course_announcement_facts`: one per extracted course change, make-up class or exam: kind, payload
  (jsonb, `course_changes` field names for course changes), evidence, check results (jsonb), whether
  it passes all checks, state (`pending`, `applied`, `approved`, `rejected`, `past`, `superseded`,
  `info`), the `course_changes` ids it produced, decided by, decided at, reason.
- `course_changes.source_announcement_id`, nullable, no foreign key cascade.

Losing options: reusing `bulletins` (served unauthenticated by `/v3/bulletins`); one jsonb blob per
announcement (review needs a row per fact to filter, count and decide). Texts are kept indefinitely
(owner's decision); production backups carry them.

### D6. One JSON-schema LLM client shared with bulletins

The HTTP, `response_format` with a caller-given schema, retry and backoff parts of
`OpenAICompatibleProvider` move into a client that returns parsed JSON; the bulletin provider keeps
its prompt and `BulletinMetadata` parsing on top of it, and course announcements add their own prompt
(the extraction rules) and schema. Both use `llm_base_url` and `llm_model`, and each extraction stores
the model name. The extraction job runs every minute and takes queued extractions only while no
bulletin is pending, so the single llama-server slot serves bulletins first. Losing options: a second
copy of the client (the project forbids duplicates); separate LLM settings for course announcements
(nothing needs them until a model swap does).

### D7. Checks are server code over the database

Class days come from the database's `course_class_days` for each course code, so the portal and the
checks agree. Term bounds come from `semester_terms`. A weekday in the evidence (「（三）」, 週三,
星期三, Wed) must match the date. Label agreement means a `cancelled` fact needs `class_cancel` at or
above 0.35 and any other kind needs `class_change` at or above 0.35. Existing changes are looked up by
term, course number, day and kind. Losing option: asking the LLM to judge its own facts (no reliable
confidence; the checks are what make automatic apply safe).

### D8. Automatic apply is a setting, approval reuses the course-changes write path

`course_announcements_auto_apply` (default false) is an environment setting the owner flips after the
shadow period; automatic writes insert `course_changes` rows with `created_by` and `updated_by` set to
`course-announcements` and the source id. In the portal, approve calls the same parse, check, insert
and `audit(...)` code as `POST /terms/{term}/changes`; edit-and-approve opens the existing change
dialog prefilled and its save carries the fact id, so the dialog's own validation applies. Losing
options: a portal toggle for automatic apply (an audited setting UI for a one-time switch); a separate
approve-with-edits endpoint (a second validation path for the same table).

### D9. Portal page

The approved mock (Course announcements under Moodle in the NAV): a Review panel with one row per
pending fact, an Announcements panel for the selected term with search, extraction filter and the
`pii` toggle, and a detail panel with the text (evidence highlighted), the 8 exam and class scores
against the 0.35 threshold and the [0.10, 0.90) band, the checks, the course changes and exams, and
Re-extract. English copy as approved with the mock. Losing option: a modal detail (the two-column
layout matches Course changes and shows a decision's context without another click).

### D10. History import through the ingest path

A local export (made outside the repository from the owner's announcement dump) holds ids, Moodle
course id, course codes, subject and message HTML, times and the attachment flag, and no author
fields. A backend command run in the container reads it, classifies in batches of 64 through the
service, stores through the same code as polling, and queues extraction for current-term
announcements the LLM rule selects. Losing option: loading the precomputed predictions file (a second
text-conversion path and scores from outside the service).

### D11. Glossary

`GLOSSARY.md` at the backend root defines course announcement (the first post of a discussion in a
course's news forum, distinct from a bulletin), extraction and pending review, in the first backend
pull request.

## Risks / Trade-offs

- [The 4B local model resolves dates wrongly or invents facts] → checks gate every write, shadow mode
  until the owner enables automatic apply, and rejected facts stay for evaluating a replacement model.
- [Announcement text names students] → stored only in the backend database, shown only behind
  Cloudflare Access with the `pii` reveal, never in app APIs, logs or fixtures; tests use invented
  text.
- [Extra Moodle traffic] → own budget capped at 20 a minute, no polling 00:00 to 05:00, rate-limit
  pauses honoured.
- [Bulletins slowed by extraction] → extraction runs only while no bulletin is pending.
- [Exam times and seating often live in attachments] → exams are informational in this change; the
  portal shows the attachment flag.
- [The classifier service has no authentication] → bound for `host.docker.internal`, firewalled from
  the network, the same as the LLM server.
- [An edit to an old announcement beyond the first page is missed] → accepted; operators can
  re-extract from the portal.

## Migration Plan

Each step needs the owner's go-ahead at the time.

1. Install the classifier on xs-mac with `deploy/install.sh model-2026-11-15`, load its launchd plist,
   add 40002 to the post-boot check.
2. Release and deploy the backend with the migration; with
   `TIGERDUCK_ANNOUNCEMENT_CLASSIFIER_URL` set, polling and extraction start in shadow mode.
3. Run the history import.
4. After two weeks of shadow mode, the owner decides on `course_announcements_auto_apply`.

Rollback: unset the classifier URL to stop the jobs; the tables stay. Automatic rows are found by
`created_by = 'course-announcements'` or `source_announcement_id` and can be deleted in the portal.
The migration's downgrade drops the new tables and column.

## Open Questions

- Which LLM model serves extraction long term. The benchmark of gemma-4-E4B against Qwen3.5-9B and
  Ornith-1.5-9B (4 and 6 bit) runs outside this change; a different model changes settings and a
  re-extract run, not this design.
- The discussions `perpage` size, set from how many posts a course makes between two polls.
