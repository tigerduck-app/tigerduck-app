#!/bin/sh
#
# Xcode Cloud post-clone hook.
#
# The fix below repairs an input that a Cloud checkout cannot have on its own.
# A missing input does not fail the build (the app just ships broken), so this
# script also verifies its own work and exits nonzero if the fix did not take.

set -e

REPO="${CI_PRIMARY_REPOSITORY_PATH:?CI_PRIMARY_REPOSITORY_PATH is not set}"
APP_DIR="$REPO/swift/TigerDuck"

# Localizations.
#
# Every `<lang>.lproj` under the Apple targets is a tracked symlink into
# `app-translation/generated/apple/`. With the submodule uncheckedout those links
# dangle, Xcode copies nothing, and the app ships with raw string keys on
# screen. The build itself still succeeds.
git -C "$REPO" submodule update --init --recursive

resolved=0
for lproj in "$APP_DIR"/*.lproj; do
    [ -e "$lproj/Localizable.strings" ] && resolved=$((resolved + 1))
done
if [ "$resolved" -lt 60 ]; then
    echo "error: only $resolved .lproj symlinks resolve; the app-translation submodule is not populated"
    exit 1
fi
echo "localizations: $resolved locales resolved"
