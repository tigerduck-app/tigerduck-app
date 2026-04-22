# BACKEND API KNOWLEDGE BASE

## OVERVIEW
`backend/api/` is a collection of POC scripts that validate NTUST / Moodle third-party endpoints *before* implementing them in the Swift client. Each script is runnable standalone and mirrors the Swift-side service layer, so Python output can be diffed against Swift behaviour.

Not a server process; no HTTP surface; no Flask/FastAPI routes.

## STRUCTURE
```text
backend/api/
├── __init__.py                 # exports RUNTIME_DIR, ENV_FILE
├── .env / .env.template        # credentials (STUDENT_ID, PASSWORD)
├── moodle/                     # Moodle-domain scripts (mirrors Swift Services/Moodle*)
│   ├── auth.py                 # Mobile App OIDC token client (long-lived token, json store)
│   ├── homework.py             # REST webservice homework fetch (main path)
│   └── legacy/
│       └── homework_sso.py     # old SSO + sesskey + ajax/service.php path (kept for diffing)
├── ntust/                      # NTUST校务系 (mirrors Swift Services/NtustSSO*)
│   ├── sso.py                  # NtustSsoBridge — cookie-based SSO, sqlite cookie store
│   ├── course_list.py          # selected courses scrape
│   └── course_lookup.py        # course info via ntust-courses pypi package
├── public/                     # No-auth public endpoints
│   ├── calendar.py             # academic year .ics URL scraper
│   └── bulletin.py             # async bulletin page scraper (writes markdown)
└── runtime/                    # Runtime artefacts (gitignored)
    ├── moodle_tokens.json      # persisted Moodle tokens (chmod 0600)
    ├── ntust_cookies.sqlite3   # SSO cookie store
    └── bulletin_pages/         # scraped bulletin markdown
```

## RUNNING SCRIPTS
All scripts run as package modules from `backend/`:

```bash
cd backend
.venv/bin/python -m api.moodle.auth              # OIDC login + token smoke test
.venv/bin/python -m api.moodle.auth --refresh    # force re-auth
.venv/bin/python -m api.moodle.homework          # REST homework list
.venv/bin/python -m api.moodle.legacy.homework_sso   # legacy SSO path for comparison
.venv/bin/python -m api.ntust.course_list
.venv/bin/python -m api.ntust.course_lookup
.venv/bin/python -m api.public.calendar
.venv/bin/python -m api.public.bulletin          # reads cached pages by default
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

## CONVENTIONS
- Python `>=3.14`, deps in `backend/pyproject.toml`, venv at `backend/.venv`
- Runtime artefacts (tokens, cookies, scraped pages) live under `runtime/` and are git-ignored
- Credentials read from `api/.env` (preferred) or env vars (fallback)
- All cross-module imports use absolute package form (`from api.moodle.auth import ...`)

## ANTI-PATTERNS
- ❌ Do not POST `/login/token.php?service=moodle_mobile_app` to NTUST Moodle — triggers login_lockout and bans the account. Use `MoodleOidcAuthClient` (OIDC flow) instead.
- ❌ Do not treat `runtime/bulletin_pages/` as source; it is generated markdown.
- ❌ Do not commit real credentials or any file under `runtime/`.
- ❌ Do not run scripts as plain file paths (`python api/moodle/auth.py`) — imports will fail. Always use `-m api.xxx` form.
