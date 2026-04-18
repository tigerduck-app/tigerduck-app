# BACKEND API KNOWLEDGE BASE

## OVERVIEW
`backend/api/` is a collection of standalone Python scripts for NTUST SSO-backed data fetching and scraping. It is not a server process; each script is an executable entry point.

## STRUCTURE
```text
backend/api/
├── ntust_sso.py              # auth/session foundation
├── course_list.py            # enrolled-course scraping
├── course_lookup.py          # course lookup/enrichment
├── get_moodle_homework.py    # Moodle assignments
├── get_calender.py           # calendar ICS links
├── bulletin/
│   ├── grepper.py            # async bulletin scraper
│   └── pages/                # scraped markdown data, not source
├── .env / .env.template      # credentials
└── ntust_cookies.sqlite3     # runtime session persistence
```

## WHERE TO LOOK
| Task | Location | Notes |
|---|---|---|
| NTUST authentication/session core | `ntust_sso.py` | Shared foundation for most scripts |
| Course selection scraping | `course_list.py`, `course_lookup.py` | Uses NTUST auth plus enrichment flow |
| Moodle assignments | `get_moodle_homework.py` | SSO + Moodle session bridge |
| Calendar link scraping | `get_calender.py` | Lighter standalone scraper |
| Bulletin scraping | `bulletin/grepper.py` | Async scraper with file output |
| Credentials/env | `.env.template` | Requires `STUDENT_ID`, `PASSWORD` |

## CONVENTIONS
- Environment setup is driven from `backend/pyproject.toml` with `uv`; Python requirement is `>=3.14`.
- Scripts use `if __name__ == "__main__"` entry points and are meant to be run individually for validation or data collection.
- `ntust_sso.py` is the backend’s shared auth/session base; most higher-level scripts build on it rather than duplicating login logic.

## ANTI-PATTERNS
- Do not count `bulletin/pages/` as code when analyzing the backend; it is generated markdown content.
- Do not assume Flask/FastAPI-style routing or request lifecycles here; there is no HTTP app surface.
- Do not commit real credentials into `.env`; use `.env.template` as the shape only.

## COMMANDS
```bash
cd backend
uv sync
python api/ntust_sso.py
python api/get_moodle_homework.py
python api/course_lookup.py
```

## NOTES
- `ntust_cookies.sqlite3` is a runtime artifact used for cookie/session persistence.
- `bulletin/grepper.py` is architecturally different from the other scripts because it is async and writes a large on-disk page corpus.
