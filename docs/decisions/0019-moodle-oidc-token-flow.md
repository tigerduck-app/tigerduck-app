# 0019. Get the Moodle token through the mobile launch OIDC flow

Status: accepted

## Context

The app needs a long-lived Moodle webservice token (`wstoken`, with its `privatetoken`) for
moodle2.ntust.edu.tw. NTUST Moodle authenticates only through OIDC (the auth_oidc plugin)
against the school SSO at ssoam2.ntust.edu.tw. Its local-password token endpoint,
`/login/token.php`, counts every request as a failed login and triggers Moodle's
`login_lockout`, which bans the account within about 10 attempts.

## Decision

`MoodleTokenService` (`swift/TigerDuck/Services/API/Moodle/MoodleTokenService.swift`) runs the
Moodle Mobile App's SSO launch flow:

1. GET `moodle2/admin/tool/mobile/launch.php` with `service=moodle_mobile_app`, a `passport` and
   `urlscheme=moodlemobile`.
2. Follow the 303s through `login/index.php` and `auth/oidc/` to `ssoam2/connect/authorize`
   (OIDC with PKCE), then the 302 to `ssoam2/account/login`.
3. Read `__RequestVerificationToken` and the hidden fields from the login form, and POST them
   with the credentials to `ssoam2/`.
4. Follow the 302 to `ssoam2/connect/authorize`, which returns a `form_post` page, and POST its
   `code`, `state` and `iss` to `moodle2/auth/oidc/`.
5. Follow the 303s to `launch.php?confirmed=0&oauthsso=0` and read
   `moodlemobile://token=<base64>` from the page.
6. Base64-decode it into `<signature>:::<wstoken>:::<privatetoken>`.

URLSession follows the redirects. `resolveTokenTriple` handles the pages that need a request of
their own (the login form, the `form_post` bridge) and the final token page, with a cap on the
number of steps. `MoodleOidcAuthClient` in `api-poc/api/moodle/auth.py` runs the same flow in
Python for probing the endpoints.

## Alternatives

- A POST to `/login/token.php?service=moodle_mobile_app` with the student ID and password: a
  single request, but each one counts as a failed login and locks the account out.

## Consequences

- Neither the app nor `api-poc/` may call `/login/token.php` on NTUST Moodle;
  `api-poc/api/AGENTS.md` states the same rule for the probes.
- The flow depends on the shape of the SSO and Moodle pages, so a change on the school's side
  breaks Moodle sign-in until the parsers follow it.
