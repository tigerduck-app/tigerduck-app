# Design

## Context

See proposal.md for why. The facts below are from tigerduck-backend `origin/dev` at 1a5a42f
(backend 4.3.0).

- `server/scheduler/runtime.py::build_scheduler` runs global APScheduler jobs in the single uvicorn
  process (`max_instances=1`, coalesce). Bulletins use `bulletin_scrape` and `bulletin_process`; the
  latter drains rows `claim_pending_bulletins` (`server/bulletins/jobs.py`) selects through the LLM
  every 60 s.
- `server/syncjobs/budget.py::RequestBudget(per_minute)` spaces requests through an httpx event hook
  that also counts `observe_sync_moodle_request()`; the executor calls `budget.pause(...)` on
  `MoodleRateLimited`. `server/main.py` builds one instance from `sync_job_requests_per_minute` (10).
- `server/syncjobs/availability.py::is_moodle_available` combines the maintenance window
  (`moodle_maintenance_start/end`, 00:00 to 05:00) with the portal's manual suspend
  (`moodle_suspended_until` in `system_settings`).
- The sync worker uses a token only while `server/syncjobs/executor.py::_has_syncing_device` holds,
  reads credentials with `server/syncjobs/credentials.py::load_credential` (which keeps the nonce), and
  marks a rejected credential invalid only after `_rejected_token_still_stored` confirms the nonce.
  `load_moodle_token` returns the token alone.
- `moodle_assignments` runs already fetch each user's enrolled Moodle courses (`FetchedCourse` with
  the numeric id, idnumber and fullname); `server/syncjobs/assignments.py::_course_nos` turns one into
  NTUST course numbers, merged sections included. Nothing stores that list per user today:
  `user_assignments` holds Moodle ids only for courses with an assignment, `user_course_overrides`
  only for app overrides, and `ntust_courses` (which mirrors ids into `user_courses`) is off by default.
- `server/syncjobs/moodle_client.py::_checked_call` maps Moodle errors to `MoodleTokenInvalid`,
  `MoodleRateLimited`, `MoodleUnavailable` and `MoodleRefused`; only `check_submission_status` uses it
  today.
- `server/bulletins/llm/openai_compat.py::OpenAICompatibleProvider` owns httpx, strict `json_schema`,
  2 retries with backoff and temperature 0.2, returns `BulletinMetadata` only, and puts model output
  into `LLMError` messages that reach logs. `settings.llm_base_url` and `settings.llm_model` point at
  the local llama-server (gemma-4-E4B, one slot).
- `course_changes` (`server/academic_calendar/models.py::CourseChange`) holds one exception per row.
  The database's `course_class_days` / `course_meetings` compute class days, so the portal and server
  share them; `server/` cannot import `portal/`. The portal writes through
  `portal/app/routes/course_changes.py` (`_parse`, `_check` with range, period and meeting clash rules,
  an advisory lock per term and course, `semester_terms ... FOR KEY SHARE`, insert, `audit(...)`).
- The portal reads and writes Postgres with asyncpg (`get_pool`); `portal/tests/test_audit_coverage.py`
  requires `await audit(` in each write route's own source and a classification for each GET.
- The classifier service (`tigerduck-app/announcement-classifier`, `scripts/serve.py`) answers
  `POST /v1/classify` with `{"posts": [{"subject", "message"}]}` (1 to 64, body up to 4 MB) and
  returns labels at its threshold, 20 scores and the converted Markdown `text`; `GET /health` returns
  the labels and threshold, not the release.

## Goals / Non-Goals

**Goals:**

- One ingest path for polled and imported announcements: store, classify, route, extract, check,
  then apply or queue.
- One set of `course_changes` validation rules for the portal and the automatic writer.
- Nothing reaches `course_changes` without passing the checks, and nothing automatically until the
  owner turns automatic apply on; applied rows change only by an operator's decision.

**Non-Goals:**

- Choosing the LLM model. It stays `settings.llm_model`; the benchmark of replacements runs outside
  this change, and a swap needs only the re-extract command.
- Reading attachments or discussion replies.

## Decisions

### D1. The classifier is a separate host service called over HTTP

The backend calls `TIGERDUCK_ANNOUNCEMENT_CLASSIFIER_URL` (unset disables the feature). It reads the
threshold and the release from `/health`; the classifier repository's `install.sh` writes the release
tag into the model folder and `serve.py` returns it. A batch that gets 413 is split in half and sent
again. Losing options: loading the model in the backend container (torch and 1.1 GB in the image and
every restart); a Docker sidecar (the same image size). The host service matches the LLM's setup, is
redeployed from the public release, and tests use a recording fake.

### D2. Course list and poll state

`moodle_assignments` runs store each user's enrolled Moodle courses (user, numeric id, idnumber,
fullname, last seen) from the list they already fetch, at no extra request. A poll state row per
current-term Moodle course holds its course codes (`_course_nos`), news forum id, latest post time,
`next_due_at` and the holder last used (`ON DELETE SET NULL`). Eligible holders are users with that
course, an active Moodle credential and `_has_syncing_device` (moved to a shared module). A job every
minute does nothing unless `is_moodle_available` and neither budget is paused; otherwise it takes the
courses with the oldest past `next_due_at`, as many as the budget allows. Losing options: deriving
courses from `user_assignments` and overrides (misses courses with no assignment); a `sync_jobs` type
per user (polls one course once per enrolled user, and needs a `job_type` migration); in-memory
schedules (lost on restart).

### D3. A second `RequestBudget` with its own metric

`course_announcement_requests_per_minute` (20) builds a second `RequestBudget`, which takes the
request observer as a parameter so it counts `tigerduck_course_announcement_moodle_requests_total`
instead of the sync counter. Moodle limits one shared address, so the poll job skips a tick while the
sync budget is paused, and on `MoodleRateLimited` it pauses both budgets itself. The tiers are
estimated at 11 to 17 requests a minute between 05:00 and 24:00. Losing options: sharing the sync
budget (a pass would stall assignment sync for over an hour); separate pauses (a rate limit on one
side would be hit again by the other).

### D4. Moodle calls

`mod_forum_get_forums_by_courses` is called per holder with that holder's courses (it silently drops
courses the user cannot see) to find each course's `type == "news"` forum, cached in the poll state.
Each poll is `mod_forum_get_forum_discussions` with `page=0` and an explicit `perpage` (Moodle's
default 0 returns the whole forum). Both go through `_checked_call`. Before writing the call, the
implementer confirms from Moodle's source how discussions are ordered (pinned and starred first, then
latest activity), how group-limited and future-visible posts appear, and sets `perpage` so pinned posts
cannot hide new ones. The poll stores `groupid` and `timestart`. On `MoodleTokenInvalid` or
`MoodleRefused` the course moves to the next holder; the poller never calls
`mark_credentials_invalid`, which needs the account and the nonce check the sync job owns. Losing
option: reading every page each poll (cost grows with the forum, for the rare edit of an old post).

### D5. Storage

New tables, enum-like columns as String plus CHECK, times as timestamptz, `term_code` without a
foreign key (the import loads terms `semester_terms` may not have), imported in `env.py` and
`test_migrations_metadata.py`:

- `user_moodle_courses`: from D2.
- `course_announcement_courses`: poll state from D2.
- `course_announcements`: id `"{discussion}-{post}"`, term code, Moodle course id, course codes, raw
  subject and message (cleared once classified), subject, converted text, posted, modified, group,
  visible-from, attachment flag, classifier release, scores (jsonb), labels, route (`unclassified`,
  `not_sent`, `sent`). Stored with `INSERT ... ON CONFLICT DO UPDATE ... WHERE excluded.modified >
  course_announcements.modified`, so polling and the import can run in any order. The same
  transaction marks older versions' pending and info items and queued or running extractions `superseded`,
  whatever the new version's route.
- `course_announcement_extractions`: per announcement version: version (`modified`), model, raw
  output (jsonb), certain, status (`queued`, `running`, `done`, `failed`, `superseded`), attempts,
  next attempt, error code. A unique partial index allows one live extraction per version.
- `course_announcement_items`: per extracted fact and course code: kind (`course_change`, `makeup`,
  `exam`), action (`add`, `replace`, `remove`), payload (jsonb, `course_changes` field names), the
  applied `course_changes` id it replaces or removes, evidence, check results (jsonb), passes-all-checks,
  state (`pending`, `applied`, `approved`, `rejected`, `past`, `superseded`, `info`, `skipped`,
  `edited`, `removed`), decided by, decided at, reason.
- `course_changes.source_announcement_id`: nullable, foreign key with `ON DELETE SET NULL`.

Losing options: reusing `bulletins` (served unauthenticated by `/v3/bulletins`); one jsonb blob per
announcement (review needs a row per item to lock, filter and count). One evidence span per fact
instead of one per field, as benchmarked: a small model quotes one span reliably, and the span must
contain the date and the change for the checks to pass. Texts are kept indefinitely; backups carry
them.

### D6. One JSON-schema LLM client shared with bulletins, with no text in errors

The HTTP, caller-given `json_schema`, retry and backoff parts of `OpenAICompatibleProvider` move into
a client that returns parsed JSON and raises errors carrying only a code and the HTTP status; neither
its log lines nor its exceptions hold model output or prompt text. The bulletin provider keeps its
prompt and `BulletinMetadata` parsing on top. Course announcements add their prompt (the benchmarked
rules plus the held-as-usual rule) and schema (the benchmarked schema plus `held_as_usual` dates).
The LLM gets the same converted text the portal shows, without the benchmark's masks, and evidence is
checked against that text. Both features use `llm_base_url` and `llm_model`; each extraction stores
the model. Losing options: a second copy of the client (the project forbids duplicates); separate LLM
settings (nothing needs them before a model swap); masking before the LLM (the masking code lives in
the classifier service, and the local LLM keeps the text on the host).

### D7. Extraction job

Every minute, while no bulletin is pending by `claim_pending_bulletins`' own condition (pending and
under its attempt limit), the job claims one queued extraction, the newest post first, in a short transaction (`running`),
calls the LLM with no transaction open, and stores the result only if the extraction is still
`running` and the announcement is still at that version; otherwise the result is discarded. Storing a
result marks the pending and info items of every earlier extraction of the announcement `superseded`, so a
same-version re-extract leaves one actionable set and one set of exams and make-up classes. Across announcements nothing is superseded: an item is marked contradicted while a later
announcement of the course holds its day as usual or holds a different change of that day and kind,
recomputed for the course's pending items whenever one of its announcements is stored or extracted,
so storage order does not matter. Losing option: superseding the earlier items (a group-only or
mistaken later post would silently remove a valid cancellation, and an older re-extract would
revive it). A failed attempt sets the next attempt 1, 4 and 16
ticks later, then `failed`. A claim older than 10 minutes (longer than the client's three 120 s
attempts) is treated as a failed attempt by the next tick, which recovers extractions a restart
interrupted. Losing options: a batch per tick (one slot is shared with bulletins, and a long batch
holds them back); resetting every `running` row at startup (a second backend process during a deploy
would reset the first one's live claim).

### D8. One validation for `course_changes`, in the database

The portal's clash and meeting rules from `_check` (range coverage, period overlap, a start or end
change naming one meeting's periods, periods that meet that day, a day with no class or a holiday)
move into the database function `course_change_violations` next to `course_class_days`, which both
the portal and the automatic writer call under the same advisory lock and `FOR KEY SHARE` on the
term. The other checks (evidence, term bounds, stated weekday 「（三）」
週三 星期三 Wed, label agreement at the service's threshold, certainty, group and visibility) are
server code. Losing options: a second copy of the rules in `server/` (they drift, and a duplicate kind
row breaks `meeting_changes`); asking the LLM to judge its own facts (no reliable confidence).

### D9. Automatic apply is an environment setting; approval reuses the course-changes write path

`TIGERDUCK_COURSE_ANNOUNCEMENTS_AUTO_APPLY` (default false) is read at start. Automatic writes call
the D8 function, insert with `created_by`/`updated_by` `course-announcements` and the source id, and
write an `admin_audit_log` row with that actor, as `server/auth/retirement.py` does for its job. In the
portal, every review action locks its item `FOR UPDATE` and refuses with 409 anything not `pending` or
whose extraction's version is not the announcement's current one;
approve runs the same parse, D8 check, write and `audit(...)` as the course-changes routes; edit and
approve opens the existing change dialog prefilled, and its save carries the item id. Deleting or
editing a sourced change in Course changes marks its item `removed` or `edited`, and a delete
marks the pending replace and remove items naming the change `superseded`. Losing options: a
portal toggle (the owner chose to flip the value in `.env` and recreate the containers; the portal's
Moodle suspend still stops polling at once); a separate approve-with-edits endpoint (a second
validation path).

### D10. Portal page

The approved mock (Course announcements under Moodle): the Review panel lists pending items with their
action (add, replace, remove) and, for a clash or a replace, the existing change; the Announcements
panel has search, an extraction filter including results that differ from the previous model, and
the reveal; the detail panel shows text and evidence behind the reveal, the 8 exam and class scores
against the service's threshold and the [0.10, 0.90) band, the checks, the items and exams, skipped
course codes, and Re-extract. Each new GET is classified as a personal read in the audit test.
Losing option: a modal detail (the two-column layout matches Course changes).

### D11. History import through the ingest path

The export script lives in the private `tigerduck-app/announcement-classifier-data` repository and
writes, to a local path outside any repository, ids, Moodle course id, course codes, subject and
message HTML, times, group, visible-from and the attachment flag, with no author fields. A backend
command in the container reads it, refuses it if any record has an author field, classifies in batches
through the service, stores through the D5 upsert, and queues extraction for current-term
announcements the route rule selects (polling queues only current-term versions too); the same command with `--reextract` queues the whole current
term for a model change. Both also queue an announcement a course change came from whatever its
route, so an edit that drops the change can still remove it. Losing option: loading the precomputed predictions (a second text-conversion
path and scores from outside the service).

### D12. Glossary

`GLOSSARY.md` at the backend root defines course announcement (the first post of a discussion in a
course's news forum, distinct from a bulletin), extraction, review item and pending review, in the
first backend pull request.

## Risks / Trade-offs

- [The local model resolves dates wrongly or invents facts] → checks gate every write, shadow mode
  until the owner enables automatic apply, applied rows change only by review, and rejected items stay
  for evaluating a replacement model.
- [Benchmark ran on masked text, production sends unmasked text] → the masks replace only URLs, emails
  and student IDs; the shadow period measures production behaviour.
- [Announcement text names students] → stored only in the backend database, shown only behind
  Cloudflare Access with the reveal, never in app APIs, logs, error fields or fixtures.
- [Extra Moodle traffic] → own budget capped at 20 a minute with its own metric, the shared
  availability rule, and pauses on either side's rate limit.
- [Bulletins slowed by extraction] → one extraction per tick, only while no bulletin is pending.
- [Exam times and seating often live in attachments] → exams are informational; the portal shows the
  attachment flag.
- [The classifier service has no authentication] → reachable only through `host.docker.internal` and
  firewalled, like the LLM server.
- [An edit to an old announcement beyond the first page is missed: Moodle's `forum_update_post`
  leaves the discussion's `timemodified` unchanged, so the edit does not bring it back to the first
  page] → accepted; operators can re-extract.
- [Turning automatic apply off needs a container restart] → accepted by the owner; the Moodle suspend
  stops new polls at once.

## Migration Plan

Each step needs the owner's go-ahead at the time.

1. Install the classifier on xs-mac with `deploy/install.sh <tag>` from a release whose `/health`
   reports the release, load its launchd plist, add 40002 to the post-boot check.
2. Release and deploy the backend with the migrations, appending
   `TIGERDUCK_COURSE_ANNOUNCEMENTS_AUTO_APPLY=false` to `.env` so enabling automatic apply is changing
   that value to `true` and recreating the containers. With `TIGERDUCK_ANNOUNCEMENT_CLASSIFIER_URL`
   set, polling and extraction start in shadow mode.
3. Run the history import (safe alongside polling).
4. After two weeks of shadow mode, the owner decides on automatic apply.

Rollback: unset the classifier URL to stop the jobs; the tables stay. Automatic rows are found by
`created_by = 'course-announcements'` or `source_announcement_id` and can be deleted in the portal.
The migrations' downgrades drop the new tables and column; the validation function's downgrade
belongs with reverting the portal PR that calls it.

## Open Questions

- An announcement classified only after its term has ended is never extracted. Whether a past term
  needs extraction is the owner's call.

Resolved: extraction uses the shared local LLM service (Qwen3.5-9B, 6-bit MLX) through
`TIGERDUCK_LLM_MODEL`; a different model changes that setting and needs a re-extract run.
