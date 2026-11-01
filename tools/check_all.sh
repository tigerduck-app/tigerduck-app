#!/usr/bin/env bash
# Runs every check that needs no Xcode, in the order of the commands block of AGENTS.md, and
# stops at the first failure.
set -u
root="$(cd "$(dirname "${BASH_SOURCE[0]:-${0}}")/.." && pwd)" || exit 2
cd "${root}" || exit 2

run() {
  echo "==> $*"
  "$@" || { echo "FAILED: $*" >&2; exit 1; }
}

run python3 tools/check_architecture.py
run python3 tools/check_account_state.py
run python3 tools/check_macos_sources.py
run python3 tools/check_privacy_manifests.py
run python3 tools/localization/check_keys.py
run python3 tools/generate_licenses.py --check
run python3 -m unittest discover -s tools -p 'test_*.py'
echo "All checks passed."
