#!/usr/bin/env bash
# Entrypoint for the backend container / uvicorn service.
#
# alembic before uvicorn so a fresh container always ends up at the latest
# schema. exec'ing uvicorn makes it PID 1, so docker stop sends SIGTERM
# straight to uvicorn and it shuts down cleanly.
set -euo pipefail

cd "$(dirname "$0")"

echo "[start.sh] alembic upgrade head"
alembic upgrade head

echo "[start.sh] launching uvicorn on :40000"
exec uvicorn server.main:app \
    --host 0.0.0.0 \
    --port 40000 \
    --proxy-headers \
    --forwarded-allow-ips '*' \
    --workers 2
