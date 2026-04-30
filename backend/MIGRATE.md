# MIGRATE.md

How to upgrade the backend to a new version without losing data.

Schema changes are managed by Alembic (`server/migrations/versions/`). Every
migration is forward-only and idempotent against `alembic_version` — running
`alembic upgrade head` against a database that is already current is a no-op.

`start.sh` runs `alembic upgrade head` before launching uvicorn, so the
common case is just: pull, rebuild, restart.

---

## TL;DR

```bash
# Same host, same DB volume — the normal upgrade.
cd backend
git pull
docker compose pull postgres            # only if Postgres image was bumped
docker compose up -d --build backend    # start.sh runs `alembic upgrade head`
docker compose logs -f backend          # confirm migrations applied cleanly
```

The named volume `tigerduck_pgdata` survives `up -d --build` and even
`down` (without `-v`), so data is preserved.

---

## Before any upgrade: take a backup

Even though migrations are reversible in principle, it is cheap insurance
and the only thing that protects you from operator error.

```bash
# From the backend/ directory, while the postgres container is running:
docker compose exec -T postgres \
  pg_dump -U tigerduck -d tigerduck --format=custom --no-owner \
  > "backup-$(date +%Y%m%d-%H%M%S).dump"
```

`--format=custom` is restorable with `pg_restore` and supports parallel
restore. `--no-owner` makes the dump portable across roles.

To restore that dump into an empty database:

```bash
docker compose exec -T postgres \
  pg_restore -U tigerduck -d tigerduck --clean --if-exists --no-owner \
  < backup-YYYYMMDD-HHMMSS.dump
```

---

## Scenario A: in-place upgrade (same host, same DB)

This is what `start.sh` automates. The volume `tigerduck_pgdata` keeps the
data; Alembic walks the version chain from whatever `alembic_version` says
up to `head`.

```bash
cd backend
git pull
docker compose up -d --build backend
```

If you want to apply migrations manually (e.g. to inspect SQL first):

```bash
# Dry-run: print the SQL that would run between current and head.
docker compose exec backend alembic upgrade head --sql

# Actually apply:
docker compose exec backend alembic upgrade head

# Inspect state:
docker compose exec backend alembic current
docker compose exec backend alembic history --verbose
```

---

## Scenario B: move to a new host / new Postgres instance

You have an old DB with real data and want the same data inside a freshly
provisioned Postgres on another machine (or a new volume). **Do not**
`cp -r` the Postgres data directory between different Postgres versions —
use `pg_dump` / `pg_restore`.

1. **Dump from the old host** (while it is still running):

   ```bash
   docker compose exec -T postgres \
     pg_dump -U tigerduck -d tigerduck --format=custom --no-owner \
     > tigerduck.dump
   ```

   The dump includes the `alembic_version` table, so the new database
   will know exactly which migration it is on after restore.

2. **Bring up the new stack with an empty DB**:

   ```bash
   # On the new host
   git clone <repo> && cd <repo>/backend
   cp .env.example .env   # fill in secrets, POSTGRES_PASSWORD, etc.
   docker compose up -d postgres
   docker compose exec postgres pg_isready -U tigerduck -d tigerduck
   ```

3. **Restore the dump** into the new (empty) `tigerduck` database:

   ```bash
   docker compose exec -T postgres \
     pg_restore -U tigerduck -d tigerduck --no-owner \
     < tigerduck.dump
   ```

4. **Start the backend**. `start.sh` runs `alembic upgrade head`. Because
   the dump carried `alembic_version` forward, this either does nothing
   (you were already at head) or applies any migrations newer than the
   dump:

   ```bash
   docker compose up -d --build backend
   docker compose logs -f backend
   ```

5. **Verify**:

   ```bash
   docker compose exec backend alembic current
   docker compose exec postgres psql -U tigerduck -d tigerduck -c \
     "select count(*) from device_registrations;"
   ```

---

## Scenario C: imported a dump that has no `alembic_version`

This happens if the dump came from a pre-Alembic snapshot or someone
exported only the data tables. Tell Alembic where the schema currently
stands without re-running migrations:

```bash
# Stamp to a specific revision that matches the schema you imported:
docker compose exec backend alembic stamp <revision_id>

# Or, if the imported schema is fully up to date:
docker compose exec backend alembic stamp head
```

`stamp` only writes to `alembic_version` — it does not run any DDL.
After stamping, `alembic upgrade head` will apply only the migrations
newer than the stamped revision.

---

## Scenario D: rolling back a bad migration

```bash
# Roll back one revision:
docker compose exec backend alembic downgrade -1

# Roll back to a specific revision:
docker compose exec backend alembic downgrade <revision_id>
```

Downgrade only works if the migration's `downgrade()` is implemented
(check the file under `server/migrations/versions/`). For destructive
migrations (column drops, type changes), restore from the `pg_dump` you
took in the "Before any upgrade" step instead.

---

## API version compatibility (clients across an upgrade)

The HTTP API mounts `/v1` as a deprecated alias of `/v2` (see
`server/main.py`). Old iOS builds that still call `/v1/...` and omit the
`platform` field continue to work — the schema defaults `platform` to
`"apple"`. Responses on `/v1/*` carry `Deprecation: true` and a
`Link: </v2/...>; rel="successor-version"` header so clients can detect
the deprecation.

To advertise a removal date set `TIGERDUCK_API_LEGACY_SUNSET` to an
RFC 8594 HTTP-date string, e.g.:

```
TIGERDUCK_API_LEGACY_SUNSET="Wed, 01 Nov 2026 00:00:00 GMT"
```

To drop `/v1` entirely, set `TIGERDUCK_API_LEGACY_BASE_PATHS=[]` (or
remove the entry) and restart.

---

## Things that do **not** require a migration

- Bumping `api_base_path` (URL change only).
- Adding a new env var in `config.py` with a default value.
- Code-only changes to dispatcher / scheduler / push routers.

If `alembic upgrade head` reports "no new upgrade operations", you are
already current — no action needed.

---

## Useful commands

```bash
# Show current revision in the live DB:
docker compose exec backend alembic current

# Show full migration history:
docker compose exec backend alembic history --verbose

# Generate a new migration after editing models.py:
docker compose exec backend alembic revision --autogenerate -m "describe change"
# Then review the generated file under server/migrations/versions/ before
# committing — autogenerate is a starting point, not the final answer.
```
