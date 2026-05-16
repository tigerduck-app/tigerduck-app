#!/usr/bin/env bash
# Stop the TigerDuck stack. Volumes are preserved.
#
# Usage:
#   ./stop.sh
set -euo pipefail
cd "$(dirname "$0")"

docker compose down
