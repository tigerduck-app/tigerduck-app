# API probes

`api-poc/` holds standalone Python scripts that probe NTUST and Moodle endpoints before the Swift
client implements them. Each script mirrors a Swift service, so its output can be compared with
the app's.

## Running scripts

`api` is a package inside the `api-poc/` workspace. Run modules from `api-poc/` with `-m`; a
script run as a file path fails its imports.

```bash
cd api-poc
uv sync
uv run python -m api.moodle.auth              # OIDC login and token smoke test
```

## Conventions

- Credentials come from `api/.env` (template: `api/.env.template`), with environment variables
  as the fallback.
- Imports use the absolute package form (`from api.moodle.auth import ...`).
- `moodle/assignments.py` (`mod_assign_get_assignments`) is the path the app uses.
  `moodle/legacy/` exists for comparison only; new code does not build on it.
- Each module's docstring holds its endpoint's gotchas; read it before changing or porting the
  module.

## Anti-patterns

- Do not POST `/login/token.php?service=moodle_mobile_app` to NTUST Moodle: it triggers the
  login lockout and bans the account. Use `MoodleOidcAuthClient` (the OIDC flow in
  `moodle/auth.py`).
- Run `api.moodle.writes` with `--commit` only to send that write: those endpoints post to
  course forums, submit assignments and change the profile picture of a real account.
