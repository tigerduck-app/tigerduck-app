#!/usr/bin/env bash
# DESTRUCTIVE: wipe the postgres volume and restart the stack with a fresh DB.
# Requires interactive confirmation. Pass --yes to skip the prompt (e.g. in CI).
#
# What it does:
#   1. docker compose down       (stops both services, keeps the image)
#   2. removes the in-use volume tigerduck_tigerduck_pgdata
#   3. also removes any stale tigerduck_* postgres volumes left over from
#      previous compose project names
#   4. docker compose up -d --build
#   5. tails the backend log so you can see alembic re-create the schema
#
# Usage:
#   ./clean-db.sh
#   ./clean-db.sh --yes
set -euo pipefail
cd "$(dirname "$0")"

confirm=true
if [[ "${1:-}" == "--yes" ]]; then
    confirm=false
fi

if $confirm; then
    cat <<'EOF'
================================================================
  THIS WILL DELETE ALL TIGERDUCK DATABASE DATA.

  Volumes that will be removed if present:
    - tigerduck_tigerduck_pgdata   (current in-use volume)
    - tigerduck_pgdata             (orphan, no compose labels)
    - tigerduck_pgdataw            (orphan, no compose labels)

  All registered devices, bulletins, and dispatch state will be
  wiped. Push tokens will need to re-register on next app launch.
================================================================
EOF
    read -r -p "Type 'wipe' to proceed: " answer
    if [[ "$answer" != "wipe" ]]; then
        echo "[clean-db] aborted."
        exit 1
    fi
fi

echo "[clean-db] docker compose down"
docker compose down

for vol in tigerduck_tigerduck_pgdata tigerduck_pgdata tigerduck_pgdataw; do
    if docker volume inspect "$vol" >/dev/null 2>&1; then
        echo "[clean-db] removing volume: $vol"
        docker volume rm "$vol"
    fi
done

echo "[clean-db] docker compose up -d --build"
docker compose up -d --build

echo
echo "[clean-db] tailing backend log (Ctrl-C to detach)..."
exec docker compose logs -f --tail=100 backend
