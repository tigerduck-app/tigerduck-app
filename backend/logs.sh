#!/usr/bin/env bash
# Tail backend logs. Pass a service name to tail something else (e.g. postgres).
#
# Usage:
#   ./logs.sh              # backend
#   ./logs.sh postgres     # postgres
set -euo pipefail
cd "$(dirname "$0")"

svc="${1:-backend}"
exec docker compose logs -f --tail=200 "$svc"
