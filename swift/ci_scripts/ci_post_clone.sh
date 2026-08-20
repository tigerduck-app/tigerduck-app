#!/bin/sh
#
# Xcode Cloud post-clone hook.
#
# Both fixes below repair inputs that a Cloud checkout cannot have on its own.
# Neither one fails the build when it is missing — the app just ships broken —
# so this script also verifies its own work and exits nonzero if either is off.

set -e

REPO="${CI_PRIMARY_REPOSITORY_PATH:?CI_PRIMARY_REPOSITORY_PATH is not set}"
APP_DIR="$REPO/swift/TigerDuck"

# 1. Localizations.
#
# Every `<lang>.lproj` under the Apple targets is a tracked symlink into
# `localization/generated/apple/`. With the submodule uncheckedout those links
# dangle, Xcode copies nothing, and the app ships with raw string keys on
# screen. The build itself still succeeds.
git -C "$REPO" submodule update --init --recursive

resolved=0
for lproj in "$APP_DIR"/*.lproj; do
    [ -e "$lproj/Localizable.strings" ] && resolved=$((resolved + 1))
done
if [ "$resolved" -lt 60 ]; then
    echo "error: only $resolved .lproj symlinks resolve; the localization submodule is not populated"
    exit 1
fi
echo "localizations: $resolved locales resolved"

# 2. API shared secret.
#
# Secrets.plist is gitignored, so it is never in a Cloud checkout. The target is
# a filesystem-synchronized group, which silently skips absent files, so the app
# ships without an `X-Push-Token` header and every write request 401s. Set
# TIGERDUCK_API_SHARED_SECRET as a *secret* environment variable on the workflow
# so its value is masked in the build logs.
: "${TIGERDUCK_API_SHARED_SECRET:?set it as a secret environment variable on the Xcode Cloud workflow}"

SECRETS="$APP_DIR/Secrets.plist"
plutil -create xml1 "$SECRETS"
plutil -insert APIToken -string "$TIGERDUCK_API_SHARED_SECRET" "$SECRETS"
plutil -lint "$SECRETS" >/dev/null
echo "Secrets.plist: written with APIToken"
