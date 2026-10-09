# API probes

`api-poc/` holds standalone Python scripts that probe NTUST and Moodle endpoints before the Swift
client implements them. Each script mirrors a Swift service, so its output can be compared with
the app's. There is no server and no HTTP surface here; the production backend is the separate
`tigerduck-app/tigerduck-backend` repository and shares no code with these scripts.

## Running scripts

`api` is a package inside the `api-poc/` workspace. Run modules from `api-poc/` with `-m`:

```bash
cd api-poc
uv sync
uv run python -m api.moodle.auth              # OIDC login and token smoke test
uv run python -m api.moodle.auth --refresh    # force re-auth
uv run python -m api.moodle.site_info         # token's site info and available functions
uv run python -m api.moodle.enrolled_courses
uv run python -m api.moodle.assignments [courseid ...]  # all enrolled courses by default
uv run python -m api.moodle.submission_status [assignid]
uv run python -m api.moodle.legacy.homework_sso   # legacy SSO path, kept for comparison
uv run python -m api.moodle.legacy.homework_calendar
uv run python -m api.moodle.enrolled_users <courseid>   # classmates and teachers
uv run python -m api.moodle.course_files <courseid>
uv run python -m api.moodle.announcements <courseid>
uv run python -m api.moodle.grades [courseid]           # overview when omitted
uv run python -m api.moodle.notifications
uv run python -m api.moodle.quizzes <courseid>
uv run python -m api.moodle.forum_posts <discussionid> [forumid]
uv run python -m api.moodle.autologin [urltogo]
uv run python -m api.moodle.writes                    # list every write payload
uv run python -m api.moodle.writes <wsfunction> k=v   # dry-run one; --commit sends it
uv run python -m api.ntust.course_list
uv run python -m api.ntust.course_lookup
uv run python -m api.ntust.score_list
uv run python -m api.ntust.classroom                  # campuses and buildings
uv run python -m api.ntust.classroom HQ EE [YYYY-MM-DD]   # one building's grid
uv run python -m api.ntust.subsystem [--en]
uv run python -m api.ntust.webmail [--limit N]
uv run python -m api.public.calendar
uv run python -m api.public.bulletin          # reads cached pages by default
```

## Conventions

- Python 3.13 or later, dependencies in `api-poc/pyproject.toml`, virtualenv in `api-poc/.venv`.
- Credentials come from `api/.env` (template: `api/.env.template`), with environment variables
  as the fallback.
- Tokens, cookies and scraped pages go under `api/runtime/`, which is gitignored.
- Imports use the absolute package form (`from api.moodle.auth import ...`).
- `moodle/assignments.py` (`mod_assign_get_assignments`) is the path the app uses.
  `moodle/legacy/` exists for comparison only; new code does not build on it.

## Anti-patterns

- Do not POST `/login/token.php?service=moodle_mobile_app` to NTUST Moodle: it triggers the
  login lockout and bans the account. Use `MoodleOidcAuthClient` (the OIDC flow in
  `moodle/auth.py`).
- Do not commit real credentials or anything under `runtime/`; do not treat
  `runtime/bulletin_pages/` as source.
- Do not run scripts as file paths (`python api/moodle/auth.py`); the imports fail. Use
  `-m api.<module>`.
- Do not run `api.moodle.writes` with `--commit` casually: those endpoints post to course
  forums, submit assignments and change the profile picture of a real account.
- Do not send `useridto=0` to the notification endpoints. Unlike the quiz ones they have no
  "0 means the current user" fallback and return accessdenied.
- Do not hardcode the cour01 pager target (`showinfo_grd$_ctl54$_ctl1`); the middle index comes
  from the row count and changes between pages.
- Do not pick a cour01 building before selecting its campus. The site answers with an HTTP 500
  error page that parses as "no grid", not as an error.
- Do not treat an empty cour01 grid as "every room is free". No grid at all is a failure; a grid
  with no rows is what weekends return.
- Do not send rendered forum text back on an edit. Read with `moodlewssettingraw=true` and
  filters off, or stored `@@PLUGINFILE@@` placeholders are replaced by absolute URLs for good.
- Do not append `?token=<wstoken>` to file URLs when `userprivateaccesskey` is available;
  rewrite to `/tokenpluginfile.php/<key>/` so the long-lived token stays out of logs and
  Referer headers.
- Do not assume imaplib decodes mailbox names: they arrive as RFC 3501 modified UTF-7
  (`&W8RO9lCZTv1TIw-`), and subjects as RFC 2047 (big5 still appears).

## Gotchas

- Moodle has two unread counters for notifications; pick by `site_info.functions[]`.
- Quiz attempts in progress only show with `status=all`.
- Forum display and edit use different `moodlewssetting*` flags.
- The browser handoff key (`moodle/autologin.py`) needs a MoodleMobile user agent and is rate
  limited to one every 6 minutes.
- cour01 uses OIDC with `form_post` and ASP.NET ViewState.
- Campus webmail is implicit TLS only: IMAP on 993, SMTP on 465.
