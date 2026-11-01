#!/bin/sh
#
# Xcode Cloud post-clone hook.
#
# A Cloud checkout has no submodules, and the build needs app-translation: every Apple target's
# "Generate Localizations" phase runs its generator with python3. Checking both here fails the
# run before the build starts instead of partway through it.

set -e

REPO="${CI_PRIMARY_REPOSITORY_PATH:?CI_PRIMARY_REPOSITORY_PATH is not set}"
GENERATOR="$REPO/app-translation/tools/localization/generate_localizations.py"

git -C "$REPO" submodule update --init --recursive

if [ ! -f "$GENERATOR" ]; then
    echo "error: $GENERATOR is missing; the app-translation submodule is not populated"
    exit 1
fi
if ! command -v python3 > /dev/null 2>&1; then
    echo "error: python3 is not on PATH; the localizations cannot be generated"
    exit 1
fi
python3 -B "$GENERATOR" --validate-only
