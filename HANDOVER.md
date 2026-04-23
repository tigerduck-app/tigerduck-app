# TigerDuck — Session Handover

**Last updated**: 2026-04-24 (post-Wave-D session)
**Branch**: `feature/backend-server` (local ahead of `origin/feature/backend-server` by 1 commit; total branch is 64 commits ahead of `main`)
**Supersedes**: `HANDOVER.md` prior revision (2026-04-23 post-Wave-A/B/C).

Read this file first. It captures the architecture, the user's working preferences, what shipped in the recent UI + subscription + scheduler work, and the gotchas that bite if you guess.

---

## 1. What TigerDuck is

iOS app (`swift/TigerDuck/`, bundle id `org.ntust.app.TigerDuck`) for NTUST students: homework (Moodle), timetable, library QR, and an **NTUST bulletin board alert pipeline** that's the current focus.

Backend (`backend/`) is a FastAPI service that:
1. Scrapes NTUST bulletins every 10 min → UPSERTs into `bulletins` table.
2. Pulls each detail page, dedups by content hash.
3. Classifies with a local LLM (`gemma-4-E4B-it` via llama.cpp) into `(canonical_org, content_tags, importance, summary, body_clean)`.
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

### Repo layout
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
│   │   ├── scheduler/runtime.py     # APScheduler wiring (5 jobs) — NEVER pass next_run_time=None
│   │   ├── migrations/      # Alembic (8ef231bb5a0c → 8e98f2ebb2d2 latest)
│   │   └── tests/           # excluded from Dockerfile; run host-side only
│   └── scripts/
│       └── backfill_bulletins.py    # one-shot, uses claim_pending_bulletins
├── api-poc/                 # ex-backend/api/; standalone uv workspace
├── swift/                   # iOS app
│   └── TigerDuck/
│       ├── Secrets.plist            # gitignored, real APIToken
│       ├── Secrets.example.plist    # committed template
│       ├── Services/Push/PushCoordinator.swift       # reads Secrets.plist
│       ├── Services/Push/PushRegistrationService.swift  # 250ms debounce on register
│       ├── Services/Core/DataCache.swift     # bulletin list + detail cache added
│       ├── Extensions/UINavigationController+Swipeback.swift  # ★ global gesture delegate
│       ├── Extensions/Date+Formatting.swift  # `fullDateString` (yyyy/MM/dd) added
│       ├── Services/API/Bulletin/            # DTO + client unchanged
│       └── Features/Bulletins/
│           ├── BulletinsView.swift           # list, long-press filter → mark-all-read
│           ├── BulletinsViewModel.swift      # cache-first + background prefetch-to-end
│           ├── BulletinReadStateStore.swift  # `markAllRead(_:)` batch helper
│           ├── BulletinSubscriptionsStore.swift  # draft-based: makeNewRule / upsert
│           ├── BulletinNotificationSettingsView.swift  # no 儲存 button, auto-save on disappear
│           └── Components/
│               ├── BulletinCardView.swift    # filled org badge + #tag strip
│               ├── BulletinDetailView.swift  # swipe-back, full-screen, markdown normalizer
│               ├── BulletinFilterBar.swift   # chip color → accentColor
│               ├── BulletinTaxonomyPickerView.swift
│               └── SubscriptionRuleEditorView.swift  # onCommit upserts draft into pending
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
TIGERDUCK_APNS_KEY_ID=<APNS_KEY_ID>              # real value lives in backend/.env only
TIGERDUCK_APNS_TEAM_ID=<APNS_TEAM_ID>            # real value lives in backend/.env only
TIGERDUCK_APNS_BUNDLE_ID=org.ntust.app.TigerDuck
TIGERDUCK_APNS_ENV=development                    # flip to production for TestFlight
TIGERDUCK_APNS_KEY_PATH=server/secrets/AuthKey_<APNS_KEY_ID>.p8
TIGERDUCK_API_SHARED_SECRET   # must match swift/TigerDuck/Secrets.plist APIToken
```

APNs `.p8` file lives at `backend/server/secrets/AuthKey_<APNS_KEY_ID>.p8` (the literal key id is intentionally not in this doc — see `backend/.env`) and is mounted read-only into the container at `/app/server/secrets`. User already has the file backed up.

### iOS Secrets.plist (swift/TigerDuck/Secrets.plist) — gitignored

```xml
<plist version="1.0"><dict>
    <key>APIToken</key>
    <string><MUST MATCH TIGERDUCK_API_SHARED_SECRET></string>
</dict></plist>
```

Read at runtime via `PushCoordinator.resolveSharedSecret()` with Info.plist fallback.

---

## 4. Recent commits (newest first)

### Wave-D session (2026-04-23 / 2026-04-24) — 11 commits

```
cbc638b feat(iOS bulletins): long-press filter toggle → 全部已讀 confirmation
a5d5962 fix: unpause scheduler jobs + force-enable swipe-back on hidden back button
4ac114b refactor(iOS bulletins/subs): draft-based rule creation, drop save button
8e36249 fix(iOS push/register): debounce double-token arrival, silence cancel noise
f3244e8 fix(iOS bulletins/detail): preserve swipe-back gesture
61aac2f fix(iOS bulletins/subs): guard load() + auto-save on editor commit
b61d5a2 refactor(iOS bulletins/detail): drop close button, extend markdown normalizer
9553a41 chore(iOS bulletins/subs): add OS Log around load/save/addRule
117abb9 feat(iOS bulletins/cache): persist list + detail, survive pagination errors
586ac67 feat(iOS bulletins/ui): filled org badge, hashtag tags, full-screen detail
```

Grouped:

- **Bulletin UI redesign**: filled accent-capsule org badge (top-left), inline `#tag` strip (bottom-right), full-screen detail reader, `yyyy/MM/dd` date, article-foot tag cloud via `FlowLayout`. Toolbar envelope → `line.3.horizontal.decrease.circle`. Filter chip + "原文公告" + tag backgrounds unified on `Color.accentColor` so they track `AppState.accentColorHex`.
- **Bulletin cache + resilient pagination**: `DataCache.saveBulletinSummaries`, `loadBulletinSummaries`, `saveBulletinDetail`, `loadBulletinDetail`. `BulletinsViewModel` seeds from cache in its init so launch paints without spinner; `paginate()` no longer clears `hasMore` on error (the "can't scroll past March" symptom was a single network blip killing all pagination); `runBackgroundPrefetch` eagerly walks the cursor to end with 200ms yields + 3-strike 2s backoff.
- **Markdown normalizer**: `BulletinDetailView.normalizeMarkdown` pre-processes LLM output — `*   ` / `+   ` bullets become `- `, and closing `**` runs next to full-width CJK punctuation get an inserted ASCII space so CommonMark's right-flanking rule fires. Three shapes covered: `**text**<punct>`, `<open-punct>**text**`, and the troublesome `**text<punct>**<letter>` (`**跨界轉身：**分享` was the reference case).
- **Subscription editor — draft model**: old `addRule()` mutated `pending` on 新增規則, so any save path (manual or auto) persisted a blank rule even when the user never tapped 完成. Replaced with `makeNewRule()` (pure factory) + `upsert(_:)`; the draft lives in view `@State draftRule` until the editor's 完成 commits it. Swipe-back from editor discards cleanly.
- **Subscription editor — auto-save**: 儲存 toolbar button removed. Auto-save fires on 完成 (upsert + save), on 刪除規則 (remove + save), and on page `.onDisappear` when `isDirty && editingClientId == nil` — the `editingClientId` check prevents the editor push from counting as "leaving the page". `didInitialLoad` flag gates `.task`-fired GET /subscriptions to exactly once, and the redundant `onChange(of: pushEnabled)` load path is gone.
- **Detail swipe-back**: `.toolbar(.hidden, for: .navigationBar)` kills `interactivePopGestureRecognizer`. Switched to `.navigationBarBackButtonHidden(true)` + `.toolbarBackground(.hidden)` and added a **global** `UINavigationController` retroactive extension in `Extensions/UINavigationController+Swipeback.swift` that swaps the gesture delegate to `viewControllers.count > 1`. That's the canonical fix.
- **Push register debounce**: `PushRegistrationService.registerIfReady` wraps its POST in a 250ms `Task.sleep`, so PTS-token + APNs-token arrivals within the debounce window coalesce into one POST instead of firing the first, cancelling it mid-flight, and firing a second. The "register failed: 已取消" log noise is gone. `CancellationError` / `NSURLErrorCancelled` silenced as expected side-effects.
- **Scheduler P0 — unpause**: `server/scheduler/runtime.py` was passing `next_run_time=None` to every `add_job`. In APScheduler that explicitly pauses the job on creation — **not** "let the trigger compute the first run". All 5 bulletin jobs had been paused since the last deploy. Parameter removed; verified post-restart that pts_tick/process/dispatch fire on schedule.
- **List: long-press → 全部已讀**: long-press (0.4s) on the filter toolbar button fires a confirmation dialog with a single "全部標示為已讀" action. `BulletinReadStateStore.markAllRead(_:)` does one Defaults union write.

### Pre-handover Wave-A/B/C session — 10 commits (reference)

```
94ba12d feat(iOS bulletins): MarkdownUI renders body_clean (P1)
8feb110 feat(iOS bulletins): local read-state with unread dot + semibold (P7)
df10f96 feat(iOS bulletins): native .searchable replaces custom toggle (P8)
fc2d4d5 feat(iOS bulletins): consume title_clean, fix picker tap, preserve clientId (P2/P9)
4f70f0e feat(bulletins): list orders by posted_at, composite cursor (P3/P6)
242f9c2 fix(bulletins): tolerate dropped enum values in stored rows
db1835a feat(backfill): --skip-scrape flag for re-classification runs
6f35d92 feat(bulletins): LLM-normalized title persisted as title_clean (P4)
4d63a00 refactor(taxonomy): reduce orgs/tags to user-facing set (P4-prep)
```

---

## 5. Gotchas that bite

### 5.1 Scheduler is single-worker
`start.sh` uses `--workers 1`. APScheduler lives in FastAPI lifespan, so N workers = N schedulers = N× scrape/LLM/dispatch calls. **Don't bump `--workers` without extracting the scheduler into its own process or wiring a pg advisory lock.**

### 5.2 **NEVER pass `next_run_time=None` to `scheduler.add_job()`**
That kwarg literally means "create this job paused". It is not "use the trigger to compute first run" — omitting the kwarg does that. Verified empirically: a job added with `next_run_time=None` has `job.next_run_time == None` after `scheduler.start()` and never fires. This killed the whole bulletin pipeline once; `server/scheduler/runtime.py` now omits the kwarg everywhere.

### 5.3 NTUST TLS requires `verify=False`
The bulletin fetch pipeline uses `verify=False` (`server/bulletins/jobs.default_http_client_factory` and `scripts/backfill_bulletins.py`). Reason:

- `bulletin.ntust.edu.tw` intermediate lacks Subject Key Identifier → rejected by OpenSSL 3 strict mode. `_ssl_compat.py` clears `VERIFY_X509_STRICT` to fix this for the list page.
- Detail pages 302-redirect to `obei.ntust.edu.tw` / `admissions.ntust.edu.tw` etc. whose servers send incomplete chains (no intermediates). Python's ssl module doesn't do AIA chasing. `verify=False` was the pragmatic MVP call.

APNs (`aioapns`) and LLM (local `host.docker.internal`) clients are untouched — only bulletin fetch goes unverified. Content is public, nothing sensitive crosses this path.

### 5.4 `INFOPLIST_KEY_*` for custom keys doesn't work
Xcode's auto-generated Info.plist only honors Apple's predefined `INFOPLIST_KEY_*` list (ITSAppUsesNonExemptEncryption, LSApplicationCategoryType, NSSupportsLiveActivities propagate; custom keys silently drop). Use a dedicated plist + `Bundle.main.url(forResource:withExtension:)` instead.

### 5.5 Register-vs-subscription race
First app launch: `PushCoordinator.registerWithServer()` (POST `/v1/devices/register`) and `BulletinSubscriptionsStore.load()` (GET `/subscriptions`) fire concurrently. Handled:
- **Server**: GET returns 200 empty when device missing. PUT still 404 so saved rules can't orphan.
- **iOS `save()`**: retries PUT on 404 with 250/500/1000ms backoff (4 attempts, ~1.75s worst case).
- **iOS register**: 250ms debounce at top of `registerIfReady`, so PTS + APNs token arrivals within the window coalesce into ONE POST.

### 5.6 postgres is not host-accessible
Host-side `pytest server/tests/test_bulletin_routes.py` will fail with `InvalidPasswordError`. Either:
- Run unit tests only (`pytest server/tests/test_bulletin_llm.py` — 14 pass, offline)
- Temporarily publish the port via `docker compose run -p 5432:5432 postgres ...`
- Skip DB tests, verify via curl against the public API

### 5.7 backfill script must use `python`, not `uv run`
Runtime image doesn't ship `uv` (only the resolved `.venv`). In the container:
```bash
docker compose exec backend python scripts/backfill_bulletins.py --pages 20 --concurrency 3
```

### 5.8 `processing_attempts` is bumped at CLAIM time
`claim_pending_bulletins` in `server/bulletins/jobs.py` is the authoritative increment point. Downstream success/failure paths only transition state. If you add another pipeline worker, route it through this helper or it'll race.

### 5.9 **Hiding the nav bar kills swipe-back**
`.toolbar(.hidden, for: .navigationBar)` disables `interactivePopGestureRecognizer` on the backing `UINavigationController`. `.navigationBarBackButtonHidden(true)` alone also disables it (UIKit default delegate). Fixed globally by `Extensions/UINavigationController+Swipeback.swift` — do **not** delete this file. If a future flow needs to lock swipe-back intentionally (e.g. mid-submission form), tighten the gesture delegate inside that view's own VC rather than removing the extension.

### 5.10 **`BulletinSubscriptionsStore.load()` MUST respect `isDirty`**
`load()` hard-fetches from server and overwrites `pending`. Earlier iterations could fire `load()` twice in rapid succession (view `.task` + `onChange(of: pushEnabled)`), with the second firing wiping a freshly-added rule to an empty array because the server had nothing yet. The `isDirty` guard is the only thing standing between in-flight edits and a clobber. Keep it.

### 5.11 **Draft-based rule creation**
Tapping 新增規則 must NOT mutate `store.pending` — only `store.makeNewRule()` (pure factory). The draft lives in view state until the editor's 完成 path calls `store.upsert(updated)`. Re-introducing an `addRule`-style mutator will reproduce the "blank rules appear on the server" bug.

### 5.12 iOS deployment target is 18.0; `Layout` protocol OK
`BulletinDetailView` uses a custom `FlowLayout` conforming to `Layout` (iOS 16+). Safe for the current 18.0 target. If someone lowers the target, this will break.

---

## 6. User's working preferences

- **Language**: reply in 繁體中文. Technical terms in English are fine.
- **Commits**: no `Co-Authored-By` footer. Split per feature/checkpoint — "frequent commits", no giant dumps. GPG signing disabled globally.
- **iOS build**: always use **iPhone 17 Pro** simulator. Never iPhone 16.
- **Python deps**: `uv add`, `uv lock`. No hand-written versions in pyproject.
- **"繼續"** = execute the plan without asking further. **"有問題再停下來問我"** = stop only on a real blocker.
- **Plan-then-execute** for architectural decisions or invasive edits (pbxproj, docker-compose, secret rotation, scheduler changes). Present plan with tradeoffs, wait for approval. Minor fixes: just do them.
- **MVP-first**: shipping beats polishing. Backups, TestFlight prod switch, Android stub etc. are explicitly deferred.
- **Auto-save over manual save buttons**: where reasonable, prefer implicit persistence on disappear / on commit over a dedicated 儲存 button. Subscription editor was refactored away from manual save per user's explicit request.
- **iOS-native gestures must work**: swipe-from-left-edge dismissal is non-negotiable on pushed views that hide the back button. Global UINavigationController extension is how we get it.
- **Dual-machine workflow**: mac-mini self-host runs Docker/llama/NPM, no full Xcode. iOS builds happen on a separate Mac; user copies changes via git. Verification logs come back to us by paste.

---

## 7. Current state (verified working)

- ✅ Docker stack: postgres + backend both healthy, `restart: unless-stopped`, no host ports.
- ✅ NPM: `api.tigerduck.app` → `http://tigerduck-internal:40000`. HTTPS via Cloudflare.
- ✅ llama-server: launchd-managed, port 40001, KeepAlive.
- ✅ iOS `X-Push-Token` auth: `Secrets.plist` carries token, matches server.
- ✅ Device registration (`apple` / `android` platform field lands correctly).
- ✅ Subscription save/load with draft model, auto-save, isDirty guard.
- ✅ Backfill: 580+ bulletins classified (2026-01-26 → 2026-04-23).
- ✅ **Bulletin scheduler alive**: post-`a5d5962` restart, pts_tick (30s), bulletin_process (60s), bulletin_dispatch (60s) all firing; bulletin_scrape (600s) confirmed 3 consecutive ticks returning 200 OK from NTUST.
- ✅ iOS bulletin list: cache-seeded instant launch, background prefetch walks 20 pages to end, resilient to single-request failures.
- ✅ iOS detail view: swipe-back works with hidden back button (global `UINavigationController` extension).
- ✅ iOS subscription settings: no manual save button; auto-saves on 完成 / 刪除 / page disappear.
- ✅ iOS long-press filter toggle: confirmation dialog → 全部標示為已讀.
- ✅ APNs push registration: 250ms debounce collapses double-token-arrival into one POST; "register failed: 已取消" noise gone.

---

## 8. Deferred TODOs (not touched, but tracked)

- **Push to origin**: branch is **1 commit ahead** of `origin/feature/backend-server` and **64 commits ahead** of `main`. User hasn't asked to push this final one; confirm before doing it.
- **Postgres daily backup**: `pg_dump` + cron/launchd. User said "MVP first", do after stability.
- **TestFlight switch**: flip `TIGERDUCK_APNS_ENV=production` in `.env` when the build ships to TestFlight. Otherwise APNs silently drops pushes.
- **iOS Secrets.plist on build Mac**: user's build Mac needs `swift/TigerDuck/Secrets.plist` created locally (gitignored). Done once; re-creation needed if they switch machines.
- **`BulletinReadStateStore.prune(keepingIdsIn:)`**: helper exists but no caller wires it up. Eventually call from list-loaded so the read set doesn't grow past retention.
- **Android path**: `platform` field exists, no FCM sender. Deferred until an actual Android client is on the roadmap.
- **Content quality pass on title_clean**: backfill produced ~600 rows; user should sample and feed bad cases back so we can tighten `SYSTEM_PROMPT`.
- **Swipe-back exceptions**: global extension lets every pushed view dismiss. If a future flow genuinely needs to lock swipe-back, tighten in that VC rather than gutting the extension.

---

## 9. Quick-reference command cheat sheet

```bash
# On the Mac self-host server (this machine)
cd /Users/xinshoutw/selfhost/Docker/tigerduck-app/backend

# Stack health
docker compose ps                                    # both 'healthy'
docker compose logs backend --tail 50                # app log (JSON structlog)
docker compose logs backend -f | grep bulletins      # live bulletin pipeline

# Confirm scheduler is actually running (not paused!)
docker compose logs backend --since 2m | grep -E "Running job|executed successfully" | tail
# Expect: pts_tick every 30s, bulletin_process/dispatch every 60s, bulletin_scrape every 600s.

# DB peek
docker compose exec postgres psql -U tigerduck -d tigerduck -c "\
  SELECT processing_state, COUNT(*) FROM bulletins GROUP BY 1;"

docker compose exec postgres psql -U tigerduck -d tigerduck -c "\
  SELECT MAX(created_at) AS newest_scraped FROM bulletins;"
# If newest_scraped is stale by hours, scheduler is paused again — check runtime.py.

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
curl -sS https://api.tigerduck.app/v1/bulletins/taxonomy | jq '.orgs | length'   # → 16

# Subscription smoke test (needs X-Push-Token from backend/.env)
docker compose exec backend python -c "
import os, urllib.request, json
req = urllib.request.Request(
    'http://localhost:40000/v1/devices/<device-id>/subscriptions',
    headers={'X-Push-Token': os.environ['TIGERDUCK_API_SHARED_SECRET']},
)
print(urllib.request.urlopen(req, timeout=5).read().decode())
"
```

---

## 10. iOS debugging filters (Console.app / Xcode)

```
subsystem:org.ntust.app.TigerDuck category:Bulletin.Subs    # subscription store events
subsystem:org.ntust.app.TigerDuck category:Bulletin.VM      # list view model (refresh/prefetch)
subsystem:org.ntust.app.TigerDuck category:Bulletin.Detail  # detail load errors
subsystem:org.ntust.app.TigerDuck category:Push.Register    # register flow (debounce swallows cancel noise)
subsystem:org.ntust.app.TigerDuck category:Push.Coord       # push stack lifecycle
```

Key events to watch:

- `subscriptions loaded count=N` — initial GET result
- `subscriptions load skipped (dirty): ...` — isDirty guard fired (good, means in-flight edits survived a re-fire)
- `upsert appended clientId=...` — draft graduated to `pending` via 完成
- `upsert updated clientId=...` — existing rule edited
- `subscription save starting / success / failed` — PUT round-trip
- `registered device=...` — APNs register POST succeeded (should appear ONCE per cold launch, not twice)

---

## 11. What to read first (next AI bootstrap path)

In order:

1. **This file** (you're here).
2. `backend/server/scheduler/runtime.py` — short, and the place one bad kwarg killed the pipeline. Gotcha 5.2.
3. `backend/server/bulletins/jobs.py` — 5 scheduler jobs + claim helper.
4. `backend/server/bulletins/llm/prompts.py` — SYSTEM_PROMPT + RESPONSE_SCHEMA.
5. `backend/server/routes/bulletins.py` — HTTP surface for iOS.
6. `swift/TigerDuck/Features/Bulletins/` — all 6 files. Start from `BulletinsView.swift` then `BulletinsViewModel.swift`. `BulletinNotificationSettingsView.swift` documents the draft-based rule model inline.
7. `swift/TigerDuck/Extensions/UINavigationController+Swipeback.swift` — small, but load-bearing for every pushed view that hides the back button.
8. `swift/TigerDuck/Services/Push/PushRegistrationService.swift` — debounce lives in `registerIfReady`.
9. `backend/server/AGENTS.md` — run commands + conventions for the server.
10. Most recent 10 commits via `git log --oneline`. Messages explain *why*.

---

## 12. When you're done

1. Update this HANDOVER if an architectural decision changes. It's the fastest path for the NEXT handover.
2. If you touch pbxproj, lint with `plutil -convert xml1 -r -o /tmp/x.plist <pbxproj>` before committing.
3. `git commit --no-gpg-sign` is not needed — signing is disabled globally.
4. Don't push to origin without explicit user confirmation.
5. Verify scheduler after any `runtime.py` change: `docker compose logs backend --since 2m | grep "executed successfully"` should show all five jobs firing. If it doesn't, you have another gotcha-5.2 situation.
