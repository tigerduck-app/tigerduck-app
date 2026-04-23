# TigerDuck — Session Handover

**Last updated**: 2026-04-23
**Branch**: `feature/backend-server` (not pushed; 19 commits ahead of `origin`)
**Replaces**: `HANDOVER_BULLETINS.md` (now obsolete, safe to delete)

Read this file first. It captures the architecture after the big backend + iOS overhaul, the user's working preferences, the pending work queue, and the gotchas that bite if you guess.

---

## 1. What TigerDuck is

iOS app (`swift/TigerDuck/`, bundle id `org.ntust.app.TigerDuck`) for NTUST students: homework (Moodle), timetable, library QR, and an **NTUST bulletin board alert pipeline** that's the current focus.

Backend (`backend/`) is a FastAPI service that:
1. Scrapes NTUST bulletins every 10 min → UPSERTs into `bulletins` table.
2. Pulls each detail page, dedups by content hash.
3. Classifies with a local LLM (`gemma-4-E4B-it` via llama.cpp) into
   `(canonical_org, content_tags, importance, summary, body_clean)`.
4. Fans out APNs push to iOS devices whose per-rule subscriptions match.

---

## 2. Final architecture (current)

```
             Mac (self-host server)
┌────────────────────────────────────────────────────────────┐
│                                                            │
│  launchd (ai.tigerduck.llm.plist)                          │
│    ↓                                                       │
│  llama-server :40001  ← NATIVE (Metal GPU, can't dockerize)│
│                                                            │
│  Docker Compose (backend/docker-compose.yml)               │
│    ┌──────────────────────────────────────────┐            │
│    │ proxy-net (192.168.97.x, external)       │            │
│    │ ├─ nginx-proxy-manager                   │            │
│    │ └─ tigerduck-internal (backend container)│            │
│    │                                          │            │
│    │ tigerduck-net (private)                  │            │
│    │ ├─ tigerduck-internal                    │            │
│    │ └─ tigerduck-postgres :5432              │            │
│    └──────────────────────────────────────────┘            │
│                                                            │
│  NO ports published to host except NPM's 443.              │
└────────────────────────────────────────────────────────────┘

iOS App → Cloudflare → Router → :443 → nginx-proxy-manager
      → api.tigerduck.app → http://tigerduck-internal:40000
```

Backend container reaches llama via `host.docker.internal:40001` (`extra_hosts: host-gateway`).

### Port map (40xxx block)

| Service | Port | Where |
|---|---|---|
| backend (uvicorn) | 40000 | container-internal only; NPM proxies |
| llama-server | 40001 | bound to 0.0.0.0 on host for container reach |
| postgres | 5432 | container-internal only, not host-exposed |

---

## 3. Where things live

### Repo layout (post-api-poc split)
```
tigerduck-app/
├── backend/                 # FastAPI push server + bulletin pipeline
│   ├── Dockerfile           # python:3.13-slim-bookworm + uv
│   ├── docker-compose.yml   # postgres + backend on proxy-net/tigerduck-net
│   ├── start.sh             # alembic upgrade head && uvicorn --workers 1
│   ├── .env                 # gitignored; real secrets
│   ├── .env.example         # committed template
│   ├── alembic.ini
│   ├── server/              # the app
│   │   ├── _ssl_compat.py   # ★ patches ssl.create_default_context
│   │   ├── main.py          # lifespan: _wait_for_llm then scheduler.start
│   │   ├── config.py        # pydantic-settings, TIGERDUCK_* env prefix
│   │   ├── models.py        # DeviceRegistration (with platform col), ScheduledPush
│   │   ├── security.py      # X-Push-Token shared-secret check
│   │   ├── bulletins/       # scraper, detail, dedup, jobs, dispatcher, matcher, LLM
│   │   │   ├── jobs.py      # scrape_job, process_job, dispatch_job, retention_job, claim_pending_bulletins
│   │   │   ├── llm/openai_compat.py   # fence-strip, retry, logging
│   │   │   └── prompts.py   # SYSTEM_PROMPT + RESPONSE_SCHEMA (JSON Schema)
│   │   ├── routes/          # /v1/devices, /v1/schedule, /v1/bulletins, /v1/debug
│   │   ├── scheduler/runtime.py     # APScheduler wiring (5 jobs)
│   │   ├── migrations/      # Alembic (8ef231bb5a0c → 8e98f2ebb2d2 latest)
│   │   └── tests/           # excluded from Dockerfile; run host-side only
│   └── scripts/
│       └── backfill_bulletins.py    # one-shot, uses claim_pending_bulletins
├── api-poc/                 # ex-backend/api/; standalone uv workspace
│   ├── pyproject.toml       # bs4/rich/ntust-courses, doesn't pollute server
│   └── api/                 # `python -m api.moodle.auth` etc.
├── swift/                   # iOS app
│   └── TigerDuck/
│       ├── Secrets.plist            # gitignored, real APIToken
│       ├── Secrets.example.plist    # committed template
│       ├── Services/Push/PushCoordinator.swift       # reads Secrets.plist
│       └── Features/Bulletins/BulletinSubscriptionsStore.swift  # save() retries 404
└── deploy/
    └── launchd/
        ├── ai.tigerduck.llm.plist   # committed plist, user symlinks into ~/Library/LaunchAgents/
        └── README.md
```

### .env (backend/.env) — gitignored

Real values are in this file on the server Mac. Keys:

```
POSTGRES_PASSWORD          # consumed by compose ${VAR} interpolation
TIGERDUCK_ENV=production
TIGERDUCK_LOG_LEVEL=INFO
TIGERDUCK_DATABASE_URL     # postgresql+asyncpg://tigerduck:<POSTGRES_PASSWORD>@postgres:5432/tigerduck
TIGERDUCK_LLM_BASE_URL     # http://host.docker.internal:40001/v1
TIGERDUCK_LLM_API_KEY=sk-local
TIGERDUCK_LLM_MODEL=gemma-4-e4b-it
TIGERDUCK_APNS_KEY_ID=5YMK3Y2A96
TIGERDUCK_APNS_TEAM_ID=43UV8F72V6
TIGERDUCK_APNS_BUNDLE_ID=org.ntust.app.TigerDuck
TIGERDUCK_APNS_ENV=development        # flip to production for TestFlight
TIGERDUCK_APNS_KEY_PATH=server/secrets/AuthKey_5YMK3Y2A96.p8
TIGERDUCK_API_SHARED_SECRET   # must match swift/TigerDuck/Secrets.plist APIToken
```

APNs `.p8` file lives at `backend/server/secrets/AuthKey_5YMK3Y2A96.p8` — mounted read-only into container at `/app/server/secrets`. User already has the file backed up.

### iOS Secrets.plist (swift/TigerDuck/Secrets.plist) — gitignored

```xml
<plist version="1.0"><dict>
    <key>APIToken</key>
    <string><MUST MATCH TIGERDUCK_API_SHARED_SECRET></string>
</dict></plist>
```

Read at runtime via `PushCoordinator.resolveSharedSecret()` with Info.plist fallback. Xcode auto-bundles it because `swift/TigerDuck/` is a `PBXFileSystemSynchronizedRootGroup` — just dropping a file in the folder adds it to the target.

---

## 4. This session's 19 commits (newest first)

```
b003f75 fix(bulletins): disable TLS verify on bulletin fetch client
31cdc2d fix(ssl): relax VERIFY_X509_STRICT for NTUST bulletin cert chain
4934160 docs(server/AGENTS): fix backfill command — drop 'uv run'
3742c16 fix(subscriptions): tolerate APNs register race on first launch
b816790 fix(iOS): switch to dedicated Secrets.plist for shared secret
2d63764 feat(iOS): wire TigerDuckAPIToken via gitignored Secrets.xcconfig   ← superseded by b816790
bb2d836 feat(deploy): version-controlled launchd plist for llama-server
eb5c56b fix(start.sh): uvicorn --workers 1 to avoid duplicate scheduler
f8360b8 feat(devices): add platform field (apple|android) to registration
97737b9 docs(server/AGENTS): rewrite RUNNING section for docker compose flow
13cf108 refactor(compose): attach backend to proxy-net, drop public ports
3fbddce feat(backend): Dockerfile + start.sh for containerized runtime
8bb16fb feat(bulletins): add daily retention job (1 year default)
b150120 fix(bulletins): atomic claim with SELECT ... FOR UPDATE SKIP LOCKED
e96fd7e feat(server/lifespan): non-blocking LLM readiness poll at startup
656f671 chore(backend): drop POC-only deps from pyproject, relocked
b531bd2 feat(api-poc): standalone uv workspace with own pyproject
c2ddda2 chore(api-poc): move backend/api/ to api-poc/api/ (git mv, no code changes)
03c1a0d chore(backend): relocate env template to backend/.env.example
8f9f5d0 chore(backend): ignore .duckversions/ env-backup directory
```

Grouped:
- **Infra**: proxy-net compose, Dockerfile, launchd plist, env cleanup, api-poc split
- **Backend hardening**: lifespan LLM-poll, SKIP-LOCKED race fix, retention job, workers=1
- **iOS**: Secrets.plist pattern (after xcconfig approach proved Xcode only honors Apple-whitelisted INFOPLIST_KEY_*), device platform field, subscriptions 404-retry
- **NTUST TLS**: `_ssl_compat` clears `VERIFY_X509_STRICT`, bulletin-fetch client uses `verify=False` (see gotchas below)

---

## 5. Gotchas that bite

### 5.1 Scheduler is single-worker
`start.sh` uses `--workers 1`. APScheduler lives in FastAPI lifespan, so N workers = N schedulers = N× scrape/LLM/dispatch calls. **Don't bump `--workers` without extracting the scheduler into its own process or wiring a pg advisory lock.**

### 5.2 NTUST TLS requires `verify=False`
The bulletin fetch pipeline uses `verify=False` (`server/bulletins/jobs.default_http_client_factory` and `scripts/backfill_bulletins.py`). Reason:

- `bulletin.ntust.edu.tw` intermediate lacks Subject Key Identifier → rejected by OpenSSL 3 strict mode. `_ssl_compat.py` clears `VERIFY_X509_STRICT` to fix this for the list page.
- Detail pages 302-redirect to `obei.ntust.edu.tw` / `admissions.ntust.edu.tw` etc. whose servers send incomplete chains (no intermediates). Python's ssl module doesn't do AIA chasing. `verify=False` was the pragmatic MVP call.

APNs (`aioapns`) and LLM (local `host.docker.internal`) clients are untouched — only bulletin fetch goes unverified. Content is public, nothing sensitive crosses this path.

### 5.3 `INFOPLIST_KEY_*` for custom keys doesn't work
Empirically verified: Xcode's auto-generated Info.plist only honors Apple's predefined `INFOPLIST_KEY_*` list (ITSAppUsesNonExemptEncryption, LSApplicationCategoryType, NSSupportsLiveActivities propagate; custom keys silently drop). Use a dedicated plist + `Bundle.main.url(forResource:withExtension:)` instead. We learned this the hard way.

### 5.4 Register-vs-subscription race
First app launch: `PushCoordinator.registerWithServer()` (POST `/v1/devices/register`) and `BulletinSubscriptionsStore.load()` (GET `/subscriptions`) fire concurrently. Fix applied:
- **Server**: GET returns 200 empty when device missing (was 404). PUT still 404 so saved rules can't orphan.
- **iOS `save()`**: retries PUT on 404 with 250/500/1000ms backoff (4 attempts, ~1.75s worst case).

If you see a fresh 404 on PUT, the retry loop probably gave up because APNs simulator handshake was unusually slow. Not a bug per se, but consider surfacing as a retry button in UI.

### 5.5 postgres is not host-accessible
Host-side `pytest server/tests/test_bulletin_routes.py` will fail with `InvalidPasswordError` — the tests expect a reachable postgres, but compose doesn't publish 5432. Either:
- Run unit tests only (`pytest server/tests/test_bulletin_llm.py` — 14 pass, offline)
- Temporarily publish the port via `docker compose run -p 5432:5432 postgres ...`
- Skip DB tests, verify via curl against the public API

Tests directory is also `.dockerignore`'d so `docker compose exec backend pytest` won't work without rebuilding the image with tests.

### 5.6 backfill script must use `python`, not `uv run`
Runtime image doesn't ship `uv` (only the resolved `.venv`). In the container:
```bash
docker compose exec backend python scripts/backfill_bulletins.py --pages 20 --concurrency 3
```
PATH has `/app/.venv/bin` prepended so bare `python` resolves to the pinned 3.13.

### 5.7 `processing_attempts` is bumped at CLAIM time
`claim_pending_bulletins` in `server/bulletins/jobs.py` is the authoritative increment point. Downstream success/failure paths only transition state. If you add another pipeline worker, route it through this helper or it'll race.

---

## 6. User's working preferences

(Observed + stated across sessions)

- **Language**: reply in 繁體中文. Technical terms in English are fine.
- **Commits**: no `Co-Authored-By` footer. Split per feature/checkpoint — "frequent commits", no giant dumps. GPG signing previously tripped; currently disabled (user set it themselves).
- **iOS build**: always use **iPhone 17 Pro** simulator. Never iPhone 16.
- **Python deps**: `uv add`, `uv lock`. No hand-written versions in pyproject.
- **"繼續"** = execute the plan without asking further. **"有問題再停下來問我"** = stop only on a real blocker.
- **Plan-then-execute**: for architectural decisions or invasive edits (pbxproj, docker-compose, secret rotation), present a plan with tradeoffs and wait for approval. Minor fixes: just do them.
- **MVP-first**: shipping the feature beats polishing. Backups, TestFlight prod switch, Android stub etc. are explicitly deferred.
- **Dual-machine workflow**: the mac-mini self-host runs Docker/llama/NPM but has no full Xcode (only CLT). iOS builds happen on a separate Mac with Xcode; user copies changes over via git. When verifying iOS changes, they do it on that machine and report back logs.

---

## 7. Current state (verified working)

- ✅ Docker stack: postgres + backend both healthy, `restart: unless-stopped`, no host ports.
- ✅ NPM: `api.tigerduck.app` → `http://tigerduck-internal:40000`. HTTPS via Cloudflare → router port-forward (user has static IP).
- ✅ llama-server: launchd-managed, port 40001, KeepAlive.
- ✅ iOS `X-Push-Token` auth: `Secrets.plist` carries token, matches server.
- ✅ Device registration (`apple` / `android` platform field lands correctly).
- ✅ Subscriptions load/save (with 404→retry for closing-save race).
- ✅ Backfill: 571 processed, 14 skipped (content dups), 0 failed (after the TLS fix + retry). ~600 bulletins classified.
- ✅ Bulletin scheduler: running every 10 min (scrape) / 60s (process, dispatch) / 24h (retention).

---

## 8. Pending work — iOS side (user's queue for next session)

The user listed the following items during the backfill verification step. They're the next session's top of the backlog.

### P1. LLM should output Markdown; iOS renders it
Currently `body_clean` already allows Markdown (prompts.py doesn't restrict). iOS just displays plain-text. Next:
- Keep / tighten LLM prompt so output is reliably Markdown (bullet lists, bold for key terms, links preserved).
- iOS swap `Text(bulletin.bodyClean)` → a proper Markdown renderer. SwiftUI's `Text(AttributedString(markdown:))` handles inline formatting out-of-the-box on iOS 15+; for richer output (links, lists, tables) consider `MarkdownUI` (MIT-licensed).

### P2. Custom subscription rules won't save/modify
Only preset-toggle or full-disable works. Reproduce:
1. Enter `BulletinNotificationSettingsView`
2. Add a new custom rule via `SubscriptionRuleEditorView`
3. Attempt save → no persist / no server hit / or silent failure
Investigate `BulletinSubscriptionsStore.save()` error state, the rule-editor's binding into `pending: [SubscriptionRule]`, and whether `SubscriptionRuleEditorView` is mutating a detached copy. PUT path itself works (verified via curl), so this is iOS-side state management.

### P3. Bulletin list sort order + default filter
- Sort by `posted_at` descending (latest first).
- Default view shows **all** bulletins (no implicit org/tag filter on first load).
`BulletinsViewModel.refresh()` likely passes filter params even when empty; trace the query-param builder and cursor pagination.

### P4. Rewrite titles to a uniform format
The raw NTUST title is often verbose and inconsistent (`【重要】轉知XX單位...`, `[轉知]...`, `公告-...`). Want the LLM to produce a normalized `title` field. Steps:
- Add `title` to `RESPONSE_SCHEMA` in `server/bulletins/llm/prompts.py` (e.g. 6–24 chars, zh-Hant, no `【】` decorations).
- Store in a new `title_clean` column — Alembic migration + ORM field + schemas.
- iOS displays `title_clean` (fallback to raw `title` if null during transition).
- Pick an exact format with the user before implementing (they haven't specified the template, just "特定格式").

### P5. All-Chinese output, fold-in English nuance
Current SYSTEM_PROMPT says "Output Traditional Chinese... Keep English only if the source itself is English." Adjust:
- If English parallel translation appears, skip it entirely in output.
- If the English copy carries info the Chinese one misses (happens for cross-dept announcements), merge the English meaning into the Chinese result but don't include English text.

### P6. iOS not showing all bulletins
Could be pagination cursor bug, filter leak, or server-side `is_deleted=true` filter that's too aggressive. Check:
- `BulletinsViewModel.refresh()` cursor reset logic
- `/v1/bulletins/` list endpoint default limits
- Count in DB vs count surfaced in app

### P7. Read/unread state (local only)
Mark-as-read when user opens detail view. Persist in SwiftData or UserDefaults keyed by bulletin_id. UI: unread gets a blue dot / bold title. No server round-trip.

### P8. Search bar: iOS 26 style
iOS 18+ `.searchable` with the new iOS 26 visual treatment (user specified "iOS26 Style"). Check `BulletinsView` for existing `.searchable` usage, upgrade modifiers per current iOS 26 HIG (likely `.searchable(text:, placement: .navigationBarDrawer(displayMode: .always))` or the new toolbar-embedded variant).

### P9. Rule editor row tap target bug
In the org/tag picker, tapping the row must trigger selection, but currently only the text area triggers. Whole row (including padding and checkmark column) should be tappable. Wrap in a `Button` or add `.contentShape(Rectangle())` + `.onTapGesture`.

### P10. (empty — user reserved)

---

## 9. Deferred TODOs (not touched, but tracked)

- **Postgres daily backup**: `pg_dump` + cron/launchd. User said "MVP first", do after stability.
- **TestFlight switch**: flip `TIGERDUCK_APNS_ENV=production` in `.env` when the build ships to TestFlight. Otherwise APNs silently drops pushes.
- **Push feature/backend-server to origin**: branch is 19 commits ahead of `origin/feature/backend-server`. User hasn't asked to push; confirm before doing it.
- **iOS TigerDuckAPIToken on the build Mac**: user's build Mac needs `swift/TigerDuck/Secrets.plist` created locally (gitignored; not auto-synced). Already done once; re-creation needed if they switch machines.
- **Ralph's feedback loop**: the code under `BulletinSubscriptionsStore` currently rotates through 4 retries; consider whether the UI should expose a manual retry button for the "超過 1.75s 還沒 register 完成" edge case.
- **Android path**: `platform` field exists, no FCM sender. Deferred until an actual Android client is on the roadmap.

---

## 10. Quick-reference command cheat sheet

```bash
# On the Mac self-host server (this machine)
cd /Users/xinshoutw/selfhost/Docker/tigerduck-app/backend

# Stack health
docker compose ps                                    # both 'healthy'
docker compose logs backend --tail 50                # app log (JSON structlog)
docker compose logs backend -f | grep bulletins      # live bulletin pipeline

# DB peek
docker compose exec postgres psql -U tigerduck -d tigerduck -c "\
  SELECT processing_state, COUNT(*) FROM bulletins GROUP BY 1;"

# Reset failed → pending (retry)
docker compose exec postgres psql -U tigerduck -d tigerduck -c "\
  UPDATE bulletins SET processing_state='pending', processing_attempts=0, \
                       processing_error=NULL WHERE processing_state='failed';"

# Backfill (manual)
docker compose exec backend python scripts/backfill_bulletins.py \
    --pages 20 --concurrency 3 --llm-timeout 240

# LLM health
curl -sS http://localhost:40001/v1/models | jq -r '.data[0].id'
launchctl list | grep tigerduck
tail -f ~/Library/Logs/tigerduck-llm.{err,out}.log

# Public API check
curl -sS https://api.tigerduck.app/health
curl -sS https://api.tigerduck.app/v1/bulletins/taxonomy | jq '.orgs | length'   # → 20

# Write endpoints need X-Push-Token (see backend/.env)
curl -sS -X POST https://api.tigerduck.app/v1/devices/register \
  -H "X-Push-Token: <the secret>" -H "Content-Type: application/json" \
  -d '{"user_id":"u","device_id":"d","pts_token_hex":"ff"}'
```

---

## 11. What to read first (next AI bootstrap path)

In order, roughly:

1. **This file** (you're here).
2. `backend/server/bulletins/jobs.py` — 5 scheduler jobs + claim helper. Short.
3. `backend/server/bulletins/llm/prompts.py` — SYSTEM_PROMPT + RESPONSE_SCHEMA. Critical for P1/P4/P5.
4. `backend/server/routes/bulletins.py` — HTTP surface for iOS.
5. `swift/TigerDuck/Features/Bulletins/` — the 6 files that compose the bulletin UI. Start from `BulletinsView.swift`.
6. `backend/server/AGENTS.md` — run commands + conventions for the server.
7. Most recent 5 commits in `git log --oneline`. They're all tightly scoped; the messages explain *why*.

---

## 12. When you're done

1. Confirm the 9 user-listed items (§8) with the user before implementation. Some need more detail (e.g. P4 title format, P7 read-state UX).
2. If you touch pbxproj, lint with `plutil -convert xml1 -r -o /tmp/x.plist <pbxproj>` before committing. Empirical history: we broke it twice before learning this.
3. The `git commit --no-gpg-sign` debate is settled — user disabled signing in `~/.gitconfig`. Just commit normally.
4. Update this HANDOVER.md if an architectural decision changes. It's the fastest path for the NEXT handover.
