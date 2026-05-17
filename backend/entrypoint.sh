#!/usr/bin/env bash
# Entrypoint for the backend container / uvicorn service.
#
# alembic before uvicorn so a fresh container always ends up at the latest
# schema. exec'ing uvicorn makes it PID 1, so docker stop sends SIGTERM
# straight to uvicorn and it shuts down cleanly.
set -euo pipefail

cd "$(dirname "$0")"

echo "[entrypoint] alembic upgrade head"
alembic upgrade head

echo "[entrypoint] launching uvicorn on :40000"
# --workers 1 on purpose: APScheduler lives inside the FastAPI lifespan, so
# every additional worker spawns a duplicate scheduler that re-runs every
# job (bulletin scrape, LLM classify, APNs dispatch) — no lock coordinates
# them. Stay single-worker until we extract the scheduler into its own
# process or wire up an advisory-lock leader election.
exec uvicorn server.main:app \
    --host 0.0.0.0 \
    --port 40000 \
    --proxy-headers \
    --forwarded-allow-ips '*' \
    --workers 1
