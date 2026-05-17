#!/usr/bin/env bash
# Bring the TigerDuck stack up (build image if needed, start postgres + backend).
# Idempotent: safe to re-run after editing code, docker-compose.yml, or .env.
#
# Usage:
#   ./start.sh
set -euo pipefail
cd "$(dirname "$0")"

docker compose up -d --build
echo
echo "[start] stack is up. tailing backend log (Ctrl-C to detach, container keeps running)..."
exec docker compose logs -f --tail=50 backend
