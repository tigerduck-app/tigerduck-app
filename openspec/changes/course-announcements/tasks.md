# Tasks

Backend pull requests go to tigerduck-backend `dev`; backend tests run on xs-mac through the
`remote-xcodebuild` skill (`uv run pytest ...`, Postgres required). Tests use fake Moodle, classifier
and LLM clients and invented announcement text; none reach the school, Moodle or a real service.

## 1. PR (backend): shared JSON-schema LLM client and glossary

- [ ] 1.1 Move the HTTP, caller-given `json_schema` response format, retry and backoff code of
  `server/bulletins/llm/openai_compat.py::OpenAICompatibleProvider` into a client that returns parsed
  JSON and raises errors with a code and HTTP status only, and rebuild the bulletin provider on it.
  Check: the bulletin LLM tests and `server/tests/test_metrics.py` pass
  (`uv run pytest server/tests -k "bulletin or llm or metrics"`).
- [ ] 1.2 Test the client with a fake transport: the schema reaches the request, invalid JSON is
  retried twice with backoff then raises, and neither the captured log nor the exception contains the
  model output or prompt. Check: the new test passes.
- [ ] 1.3 Add `GLOSSARY.md` at the backend root (design D12). Check: reviewed in the PR.

## 2. PR (classifier repository): release in `/health`

- [x] 2.1 In `tigerduck-app/announcement-classifier`, have `deploy/install.sh` write the tag to
  `model/RELEASE` and `scripts/serve.py` return it as `release` in `/health` (existing releases work
  with the new script). Check: `scripts/test_serve.py` asserts the field with and without the file.

## 3. PR (backend): course list, storage, polling and classification

- [ ] 3.1 Add `deploy/launchd/ai.tigerduck.classifier.plist` and a section in
  `deploy/launchd/README.md` on `deploy/install.sh <tag>`. Check:
  `plutil -lint deploy/launchd/ai.tigerduck.classifier.plist`.
- [ ] 3.2 Add settings `announcement_classifier_url` (unset disables the feature),
  `course_announcement_requests_per_minute` (20) and `course_announcements_auto_apply` (false) to
  `server/config.py`, `.env.example` and `server/AGENTS.md`. Check: a settings test reads each from its
  `TIGERDUCK_` variable.
- [ ] 3.3 Add the models and a migration for `user_moodle_courses`, `course_announcement_courses`,
  `course_announcements`, `course_announcement_extractions`, `course_announcement_items` and
  `course_changes.source_announcement_id` (design D5), with the upsert condition and the one-live-
  extraction index. Check: `uv run pytest server/tests/test_migrations_metadata.py` and a new
  `server/tests/test_migration_course_announcements.py` that upgrades and downgrades.
- [ ] 3.4 Store each user's enrolled Moodle courses from the list `moodle_assignments` runs already
  fetch. Check: an executor test finds the rows after a run and no extra Moodle request.
- [ ] 3.5 Let `RequestBudget` take its request observer, add the course announcement counter, and move
  `_has_syncing_device` where the poller can share it. Check: budget tests for each observer and the
  existing executor tests pass.
- [ ] 3.6 Add `mod_forum_get_forums_by_courses` and `mod_forum_get_forum_discussions` through
  `_checked_call` on a client with the second budget. First confirm from Moodle's source the discussion
  order (pinned, starred, latest activity), group-limited and future-visible posts, and the effect of
  `perpage`, and cite the source in a comment. Check: fake-transport tests for both calls, a pinned
  forum that still shows a new post, `groupid` and `timestart` parsed, and token scrubbing in errors.
- [ ] 3.7 Add the classifier client (batches of up to 64, split on 413, threshold and release from
  `/health`) and a recording fake. Check: tests for a batch, a 413 split, a 400 and the service down.
- [ ] 3.8 Build the poll job: current-term courses from `user_moodle_courses` with `_course_nos`,
  eligible holders, the recency tiers, most-overdue-first within the budget, `is_moodle_available`,
  skipping while either budget is paused, pausing both on a rate limit, and the next holder on
  `MoodleTokenInvalid` or `MoodleRefused` without marking the credential. Check: tests for each tier
  boundary, the manual suspend, selection order, holder eligibility, both pause paths and holder
  fallback with no credential change.
- [ ] 3.9 Build ingest: the upsert by later `modified`, merged course codes, no author fields, raw
  subject and message kept until classified, a classify-pending step each tick, and the route rule.
  Check: tests for new, edited, older, unchanged, merged sections, classifier down then up without a
  second Moodle fetch, and the route rule at 0.10, 0.90 and a confident fact label.
- [ ] 3.10 Register the poll job in `build_scheduler` only when the classifier URL and the credential
  cipher are set. Check: a scheduler test for each combination.

## 4. PR (backend): one `course_changes` validation for portal and server

- [ ] 4.1 Move the clash and meeting rules of `portal/app/routes/course_changes.py::_check` into a
  database function next to `course_class_days` (migration plus model SQL), keep the portal's advisory
  lock and `FOR KEY SHARE`, and call the function from the portal. Check: the existing portal
  course-changes tests pass unchanged, plus a test of the function on a range covering a day, period
  overlap and a two-meeting start change.

## 5. PR (backend): extraction, checks, items and apply

- [ ] 5.1 Add the extraction prompt (the benchmarked rules without the mask sentence, plus the
  held-as-usual rule) and schema (the benchmarked schema plus `held_as_usual` dates) on the client from
  1.1, storing the model and raw output. Check: fake-LLM tests for a cancellation, a room change, a
  held-as-usual notice, an exam and an invalid answer.
- [ ] 5.2 Add the extraction job of design D7: bulletins first by `claim_pending_bulletins`' condition,
  one claim per tick, no transaction during the call, version check before storing, earlier pending
  items superseded on store, retries at 1, 4 and 16 ticks, then `failed`, a claim older than 10
  minutes counted as a failed attempt; operator-queued re-extraction. Check: tests for bulletin-first,
  a stuck bulletin at its attempt limit not blocking, edit during extraction, a same-version
  re-extract superseding earlier items, an abandoned claim recovered, the retry schedule and failure.
- [ ] 5.3 Add the checks of design D8 per course code, calling the 4.1 function. Check: one test per
  check, including a clash with a range change and a group-limited post.
- [ ] 5.4 Turn extractions into items: add, replace and remove per course code; remove for an applied
  change the new extraction lacks or a held-as-usual date (from this or a later announcement of the
  course) covers; skipped codes without a TigerDuck schedule; makeups and exams as `info`; past at
  extraction and by a daily pass in Taipei time. Check: tests for each action, the withdrawn
  cancellation, skipped codes and both past paths.
- [ ] 5.5 Add apply: shadow mode marks passing add items; with automatic apply on, apply an
  announcement's add items only when all of them pass, the announcement has no replace or remove item,
  and none matches an earlier rejected or removed item, through the 4.1 function under the advisory
  lock, with the source id, the actor and an `admin_audit_log` row. Check: tests for shadow mode, auto
  apply, one failing item holding the announcement, a corrected date holding its add, no re-apply
  after an operator deletion, and the audit row.
- [ ] 5.6 Keep `/v4/calendar/course-changes` responses unchanged by the new column. Check: the
  calendar API tests pass and a test asserts the response fields.

## 6. PR (backend): portal Course announcements page

- [ ] 6.1 Add `portal/app/routes/course_announcements.py` mounted in `main.py`: term announcements
  (search, extraction filter including results that differ from the previous model, pagination), one
  announcement's detail, the review list, approve, reject with a reason, and queue re-extraction. Each
  write route locks its item, refuses non-pending items with 409 and calls `await audit(` itself; each
  GET is classified as a personal read. Check: route tests for double approve, stale approve (a newer
  version and a same-version re-extract), reject-then-approve, and
  `portal/tests/test_audit_coverage.py`.
- [ ] 6.2 Let the course-changes create and update calls carry an optional item id for edit and
  approve, and have their edit and delete routes mark a sourced change's item `edited` or `removed`.
  Check: route tests for each path.
- [ ] 6.3 Build `portal/web/src/pages/course-announcements.tsx` from the approved mock with the NAV
  entry, route and types: item actions, the existing change for a clash or replace, skipped codes,
  text and evidence behind the reveal. Check: the portal web build, type check and lint pass, and
  headless Chromium screenshots at desktop and 375 px with long subjects and three-digit counts show
  no overflow.

## 7. PR (backend) and private repository: history import

- [ ] 7.1 Add the backend import command of design D11, with `--reextract`. Check: tests with an
  invented export for a first run, a second run that stores and queues nothing, an author field that
  stops the run, a run alongside a poll of the same announcement, and `--reextract`.
- [ ] 7.2 Add the export script to `tigerduck-app/announcement-classifier-data`, writing to a local
  path outside every repository. Check: run it locally and confirm with a key scan that no record has
  an author field.

## 8. Release and rollout (owner's go-ahead at each step)

- [ ] 8.1 Install the classifier on xs-mac from the 2.1 release, load the plist, and add port 40002 to
  the post-boot check. Check: `/health` reports the release on the host and through
  `host.docker.internal` from the backend container.
- [ ] 8.2 Release the backend with a `MIGRATE.md` section and deploy it with the classifier URL set,
  appending `TIGERDUCK_COURSE_ANNOUNCEMENTS_AUTO_APPLY=false` to xs-mac's `.env` without reading the
  file (a key-count check may confirm the key is absent). Check: the post-deploy check passes, logs
  show poll ticks, and `tigerduck_course_announcement_moodle_requests_total` grows by at most 20 a
  minute.
- [ ] 8.3 Run the history import. Check: read-only counts of stored announcements and queued
  extractions in production.
- [ ] 8.4 After two weeks in shadow mode, compare the items marked as passing with operator decisions
  and let the owner decide on automatic apply. Check: the owner's decision recorded where it is
  flipped.

## Workflow follow-up

- Archive with `openspec archive course-announcements` after the last pull request merges.
