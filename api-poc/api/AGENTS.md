# API POC KNOWLEDGE BASE

## OVERVIEW
`api-poc/` is a collection of POC scripts that validate NTUST / Moodle third-party endpoints *before* implementing them in the Swift client. Each script is runnable standalone and mirrors the Swift-side service layer, so Python output can be diffed against Swift behaviour.

Not a server process; no HTTP surface; no Flask/FastAPI routes. Lives alongside `backend/` and `swift/` at the repo root, with its own `pyproject.toml` so POC dependencies (bs4, rich, ntust-courses) do not pollute the production server image.

## STRUCTURE
```text
api-poc/
├── pyproject.toml              # workspace deps (bs4, httpx, rich, ntust-courses, ...)
├── .python-version             # 3.13
└── api/                        # the Python package — cd api-poc && uv run python -m api.xxx
    ├── __init__.py             # exports RUNTIME_DIR, ENV_FILE
    ├── .env / .env.template    # credentials (STUDENT_ID, PASSWORD)
    ├── moodle/                 # Moodle-domain scripts (mirrors Swift Services/Moodle*)
    │   ├── auth.py             # Mobile App OIDC token client (long-lived token, json store)
    │   ├── homework.py         # REST webservice homework fetch (main path)
    │   ├── notifications.py    # notification centre: list, unread counts, preferences
    │   ├── quizzes.py          # mod_quiz: quizzes, user attempts, best grade
    │   ├── forum_posts.py      # thread contents, edit-shaped post, forum capabilities
    │   ├── autologin.py        # browser handoff key + tokenpluginfile URL rewriting
    │   ├── writes.py           # every type=write wsfunction — DRY-RUN by default
    │   └── legacy/
    │       └── homework_sso.py # old SSO + sesskey + ajax/service.php path (kept for diffing)
    ├── ntust/                  # NTUST校务系 (mirrors Swift Services/NtustSSO*)
    │   ├── sso.py              # NtustSsoBridge — cookie-based SSO, sqlite cookie store
    │   ├── course_list.py      # selected courses scrape
    │   ├── course_lookup.py    # course info via ntust-courses pypi package
    │   ├── classroom.py        # cour01 room occupancy (OIDC form_post + WebForms grid)
    │   ├── subsystem.py        # i.ntust portal service directory
    │   └── webmail.py          # mail.ntust IMAP/SMTP (stdlib imaplib/smtplib)
    ├── public/                 # No-auth public endpoints
    │   ├── calendar.py         # academic year .ics URL scraper
    │   └── bulletin.py         # async bulletin page scraper (writes markdown)
    └── runtime/                # Runtime artefacts (gitignored)
        ├── moodle_tokens.json  # persisted Moodle tokens (chmod 0600)
        ├── ntust_cookies.sqlite3   # SSO cookie store
        └── bulletin_pages/     # scraped bulletin markdown
```

## RUNNING SCRIPTS
Package imports (`from api.moodle.auth import ...`) stay unchanged from the pre-move era — the `api` folder is a Python package sitting inside this workspace. Run from `api-poc/`:

```bash
cd api-poc
uv sync
uv run python -m api.moodle.auth              # OIDC login + token smoke test
uv run python -m api.moodle.auth --refresh    # force re-auth
uv run python -m api.moodle.homework          # REST webservice homework list
uv run python -m api.moodle.legacy.homework_sso   # legacy SSO path for comparison
uv run python -m api.moodle.enrolled_users <courseid>   # classmates + teachers of a course
uv run python -m api.moodle.course_files <courseid>     # downloadable files in a course
uv run python -m api.moodle.announcements <courseid>    # news-forum announcements
uv run python -m api.moodle.grades [courseid]           # grade items, or overview when omitted
uv run python -m api.moodle.notifications             # notification centre
uv run python -m api.moodle.quizzes <courseid>        # quizzes + attempts + best grade
uv run python -m api.moodle.forum_posts <discussionid> [forumid]
uv run python -m api.moodle.autologin [urltogo]       # browser handoff key
uv run python -m api.moodle.writes                    # list every write payload
uv run python -m api.moodle.writes <wsfunction> k=v   # dry-run one (add --commit to send)
uv run python -m api.ntust.course_list
uv run python -m api.ntust.course_lookup
uv run python -m api.ntust.classroom                  # campuses + buildings
uv run python -m api.ntust.classroom HQ EE [YYYY-MM-DD]   # one building's grid
uv run python -m api.ntust.subsystem [--en]           # portal service directory
uv run python -m api.ntust.webmail [--limit N]        # IMAP folders + recent headers
uv run python -m api.public.calendar
uv run python -m api.public.bulletin          # reads cached pages by default
```

## WHERE TO LOOK
| Task | Location | Notes |
|---|---|---|
| Moodle auth (production) | `moodle/auth.py` | OIDC via launch.php — DO NOT replace with /login/token.php |
| Moodle webservice calls | `moodle/homework.py` | uses `MoodleOidcAuthClient.call(wsfunction, ...)` |
| Moodle legacy path | `moodle/legacy/homework_sso.py` | kept for parity diffing, not for new code |
| NTUST SSO session | `ntust/sso.py` | `NtustSsoBridge` cookie flow, sqlite persistence |
| Course selection scrape | `ntust/course_list.py`, `ntust/course_lookup.py` | SSO + optional `ntust_courses` enrichment |
| Academic calendar ICS | `public/calendar.py` | public page, no auth |
| Bulletin scraper | `public/bulletin.py` | async httpx + rich progress, writes into `runtime/bulletin_pages/` |
| Moodle notifications | `moodle/notifications.py` | two unread counters; pick by `site_info.functions[]` |
| Moodle quizzes | `moodle/quizzes.py` | `status=all` is required to see in-progress attempts |
| Forum thread / edit | `moodle/forum_posts.py` | display vs edit `moodlewssetting*` flags differ |
| Browser handoff | `moodle/autologin.py` | needs a MoodleMobile UA; 6-minute rate limit |
| Write endpoints | `moodle/writes.py` | payload + response-envelope reference, dry-run |
| Room occupancy | `ntust/classroom.py` | OIDC `form_post`, ASP.NET ViewState, pager target varies |
| Portal directory | `ntust/subsystem.py` | enumerates every campus service URL — good for discovery |
| Campus webmail | `ntust/webmail.py` | IMAP 993 / SMTP 465 implicit TLS only |

## CONVENTIONS
- Python `>=3.13`, deps in `api-poc/pyproject.toml`, venv at `api-poc/.venv`
- Runtime artefacts (tokens, cookies, scraped pages) live under `api/runtime/` and are git-ignored
- Credentials read from `api/.env` (preferred) or env vars (fallback)
- Cross-module imports use absolute package form (`from api.moodle.auth import ...`)

## ANTI-PATTERNS
- Do not POST `/login/token.php?service=moodle_mobile_app` to NTUST Moodle — triggers login_lockout and bans the account. Use `MoodleOidcAuthClient` (OIDC flow) instead.
- Do not treat `runtime/bulletin_pages/` as source; it is generated markdown.
- Do not commit real credentials or any file under `runtime/`.
- Do not run scripts as plain file paths (`python api/moodle/auth.py`) — imports will fail. Always use `-m api.xxx` form.
- Do not run `api.moodle.writes` with `--commit` casually: those endpoints post to course forums, submit assignments and change the profile picture on a real account.
- Do not send `useridto=0` to the notification endpoints — unlike the quiz ones they have no "0 means current user" fallback and return accessdenied.
- Do not hardcode the cour01 pager target (`showinfo_grd$_ctl54$_ctl1`): the middle index is derived from the row count and changes between pages.
- Do not pick a cour01 building before selecting its campus — the site answers with an HTTP 500 error page that parses as "no grid", not as an error.
- Do not treat an empty cour01 grid as "every room is free": no grid at all is a failure, a grid with no rows is what weekends legitimately return.
- Do not send rendered forum text back on an edit. Read with `moodlewssettingraw=true` and filters off, or stored `@@PLUGINFILE@@` placeholders get replaced by absolute URLs permanently.
- Do not append `?token=<wstoken>` to file URLs when `userprivateaccesskey` is available; rewrite to `/tokenpluginfile.php/<key>/` so the long-lived token stays out of logs and Referer headers.
- Do not assume imaplib decodes mailbox names: they arrive as RFC 3501 modified UTF-7 (`&W8RO9lCZTv1TIw-`), and subjects as RFC 2047 (big5 still appears).
