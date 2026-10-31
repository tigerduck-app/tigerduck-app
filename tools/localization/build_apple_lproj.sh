#!/bin/sh
# Generates the Apple localizations from the app-translation submodule and copies each
# <lang>.lproj into the bundle being built. The "Generate Localizations" Run Script phase of every
# Apple target runs it; it writes nothing into the checkout.
#
#   tools/localization/build_apple_lproj.sh --list > tools/localization/apple-lproj.xcfilelist
#
# rewrites the phase's output file list after a locale is added or removed. The build sandbox lets
# the script write only the paths that list declares, so the build fails while the two differ.

set -eu
export LC_ALL=C

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
GENERATOR="$ROOT/app-translation/tools/localization/generate_localizations.py"
OUTPUT_LIST="$ROOT/tools/localization/apple-lproj.xcfilelist"
FILES="InfoPlist.strings Localizable.strings"
MIN_LOCALES=60

fail() {
    echo "error: $*" >&2
    exit 1
}

command -v python3 > /dev/null 2>&1 || fail "python3 is not on PATH, so the localizations cannot be generated"
[ -f "$GENERATOR" ] || fail "$GENERATOR is missing; run git submodule update --init --recursive"

if [ "${1:-}" = --list ]; then
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
else
    # The sandbox allows the target's temp folder but not DERIVED_FILE_DIR inside it.
    work="${TARGET_TEMP_DIR:?run from an Xcode build phase, or pass --list}/AppleLocalizations"
    rm -rf "$work"
fi

python3 -B "$GENERATOR" --platform apple --output-dir "$work" > /dev/null
locales=$(cd "$work" && ls -d -- *.lproj | sed 's/\.lproj$//')
count=$(printf '%s\n' "$locales" | grep -c . || true)
[ "$count" -ge "$MIN_LOCALES" ] || fail "the generator wrote $count locales, fewer than $MIN_LOCALES"

outputs() {
    echo "# The outputs of tools/localization/build_apple_lproj.sh, written by its --list option."
    for locale in $locales; do
        dir="\$(TARGET_BUILD_DIR)/\$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/$locale.lproj"
        echo "$dir"
        for file in $FILES; do
            echo "$dir/$file"
        done
    done
}

if [ "${1:-}" = --list ]; then
    outputs
    exit 0
fi

[ "$(outputs)" = "$(cat "$OUTPUT_LIST")" ] \
    || fail "$OUTPUT_LIST does not list the generator's $count locales; run $0 --list > $OUTPUT_LIST"

dest="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
for locale in $locales; do
    mkdir -p "$dest/$locale.lproj"
    for file in $FILES; do
        cp "$work/$locale.lproj/$file" "$dest/$locale.lproj/$file"
    done
done
echo "localizations: $count locales copied into $dest"
