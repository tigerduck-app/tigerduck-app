# PUSH NOTIFICATION SERVER KNOWLEDGE BASE

## OVERVIEW
`backend/server/` is the push notification backend. Distinct from `backend/api/`
which is POC-only. Runs on the Mac mini behind nginx-proxy-manager + Cloudflare,
serves the iOS app at `https://api.tigerduck.app/v1/`.

**Scope (Checkpoint 1, current):**
- Device registration (stores PTS token)
- Schedule sync (client-authoritative list of next-48h events)
- APNs Push-to-Start payload builder + sender (no live dispatcher yet)

**Out of scope (future checkpoints):**
- APScheduler dispatcher (Checkpoint 3)
- Announcement polling + broadcast (future sprint)
- Live Activity update-token push (deferred; MVP relies on `timerInterval` animation)

## STRUCTURE
```text
backend/server/
├── __init__.py
├── main.py                 # FastAPI app + lifespan
├── config.py               # pydantic-settings, TIGERDUCK_ prefix
├── logging_setup.py        # structlog console/JSON
├── db.py                   # Base, async engine/session, SessionDep
├── models.py               # DeviceRegistration, ScheduledPush, build_push_id
├── schemas.py              # Pydantic request/response
├── routes/
│   ├── devices.py          # /v1/devices/register, /unregister, /{id}
│   └── schedule.py         # /v1/schedule/sync, /v1/schedule/{device}/{source}
├── push/
│   ├── payload.py          # build_apns_request, build_pts_payload
│   └── apns_client.py      # AioApnsSender + RecordingSender (factory)
├── migrations/             # Alembic, async template, targets server.db.Base
├── secrets/                # .p8 key here (gitignored)
├── .env.template
└── tests/                  # pytest-asyncio integration + unit tests
```

## RUNNING

### Production (docker compose, proxy-net)
```bash
cd backend
cp .env.example .env                      # then fill in real values
docker compose up -d --build              # builds Dockerfile, brings up postgres + backend

docker compose logs -f backend            # follow; look for "server.startup" and "llm.ready"
docker compose exec backend curl -sS localhost:40000/health
```

nginx-proxy-manager (on proxy-net) routes `api.tigerduck.app` to
`http://tigerduck-internal:40000`. No ports are published to the host.
Postgres is private to `tigerduck-net` and unreachable from outside the
backend container.

`llama-server` stays NATIVE on the host (Docker on Mac can't get Metal GPU).
The backend reaches it via `host.docker.internal:40001`. See
`deploy/launchd/ai.tigerduck.llm.plist` for the launchd service.

### One-shot backfill
```bash
# NOTE: the production image only bundles the .venv (no uv). Call python
# directly — /app/.venv/bin is on PATH so it resolves to the pinned 3.13.
docker compose exec backend \
  python scripts/backfill_bulletins.py --pages 20 --concurrency 3
```

### Tests (host-side, not inside container)
```bash
uv sync
uv run pytest server/tests/ -v            # LLM + pipeline tests; DB-backed ones need postgres up
```

## CONFIG
All env vars use the `TIGERDUCK_` prefix. See `.env.example` for the full,
commented list. Drop APNs credentials under
`server/secrets/AuthKey_<KEY_ID>.p8` — the path is mounted read-only into
the backend container via docker-compose.

## CONVENTIONS
- All DB timestamps stored as `timestamp with time zone` (UTC in, UTC out)
- Session management: `SessionDep` in routes auto-commits/rolls-back
- `push_id = f"{device_id}:{source_id}:{scenario}"` — deterministic so client
  UPSERTs are idempotent
- `schedule/sync` = full replacement per device (pending pushes not in the
  payload get cancelled, sent/failed history preserved)
- APNs topic for PTS: `{bundle_id}.push-type.liveactivity` (payload builder
  handles this — do not hardcode elsewhere)

## ANTI-PATTERNS
- ❌ Do not store user Moodle/NTUST credentials in this service. The design
  assumes the client owns credentials; the server only knows schedule metadata.
- ❌ Do not send APNs pushes from inside request handlers. Scheduling goes
  through `scheduled_pushes` and is dispatched asynchronously (Checkpoint 3).
- ❌ Do not commit `.env`, `server/secrets/*.p8`, or anything under
  `server/migrations/versions/` without reviewing first (migrations are fine
  to commit; the warning is to avoid accidentally committing test SQL dumps).
- ❌ Do not use the standard `apns-topic: {bundle_id}` for Live Activities;
  iOS will silently drop the push.
