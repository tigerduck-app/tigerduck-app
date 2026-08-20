#!/usr/bin/env python3
"""Fail when Swift references a localization key the translation repo lacks.

`String(localized: "x")` returns `"x"` verbatim when the key is missing, so an
app that has drifted from `localization/` still compiles, still archives, and
still uploads — the raw key only surfaces on a device. TestFlight builds 89-91
shipped that way. This check turns the drift into a build failure.

Run it locally with no arguments; it exits nonzero and lists `file:line` for
every offending reference.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWIFT_DIR = ROOT / "swift"
# Every locale carries an identical key set, so one reference file is enough.
REFERENCE = ROOT / "localization" / "generated" / "apple" / "en.lproj" / "Localizable.strings"
BASELINE = Path(__file__).with_name("known-missing-keys.txt")

PATTERNS = [
    re.compile(r'String\(\s*localized:\s*"([A-Za-z0-9_.]+)"'),
    re.compile(r'LocalizedStringKey\(\s*"([A-Za-z0-9_.]+)"'),
    re.compile(r'NSLocalizedString\(\s*"([A-Za-z0-9_.]+)"'),
    # SwiftUI treats a `Text` string literal as a LocalizedStringKey. Only
    # snake_case literals are read as keys — display text like "—" or
    # "GPA %.2f" is not a lookup and must not be flagged.
    re.compile(r'Text\(\s*"([a-z0-9]+(?:_[a-z0-9]+)+)"'),
]

# ponytail: line-oriented matching, so a call split across lines is missed.
# That under-reports; it never produces a false failure. Move to a real Swift
# parser only if a wrapped call ever ships a placeholder.


def translated_keys() -> set[str]:
    if not REFERENCE.exists():
        sys.exit(
            f"error: {REFERENCE.relative_to(ROOT)} not found — run "
            "`git submodule update --init --recursive` first."
        )
    return {
        m.group(1)
        for m in (
            re.match(r'^"([^"]+)"\s*=', line)
            for line in REFERENCE.read_text(encoding="utf-8").splitlines()
        )
        if m
    }


def referenced_keys() -> dict[str, list[str]]:
    """key -> ["<path>:<line>", ...] for every reference in the Swift sources."""
    found: dict[str, list[str]] = {}
    for swift in sorted(SWIFT_DIR.rglob("*.swift")):
        rel = swift.relative_to(ROOT)
        for lineno, line in enumerate(swift.read_text(encoding="utf-8").splitlines(), 1):
            for pattern in PATTERNS:
                for key in pattern.findall(line):
                    found.setdefault(key, []).append(f"{rel}:{lineno}")
    return found


def baseline_keys() -> set[str]:
    if not BASELINE.exists():
        return set()
    return {
        line.strip()
        for line in BASELINE.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    }


def main() -> int:
    translated = translated_keys()
    referenced = referenced_keys()
    baseline = baseline_keys()

    missing = {k: v for k, v in referenced.items() if k not in translated}
    new = {k: v for k, v in missing.items() if k not in baseline}

    resolved = sorted(baseline - set(missing))
    if resolved:
        print(
            f"note: {len(resolved)} baselined key(s) now translated; drop them "
            f"from {BASELINE.name}: {', '.join(resolved)}"
        )

    if not new:
        print(f"OK {len(referenced)} keys referenced, {len(translated)} translated, "
              f"{len(missing)} baselined")
        return 0

    for key in sorted(new):
        for site in new[key]:
            print(f"::error file={site.split(':')[0]},line={site.split(':')[1]}::"
                  f"Localization key '{key}' has no translation in localization/. "
                  f"It will render as the raw key.")
    print(f"\nerror: {len(new)} localization key(s) missing from the translation "
          f"repo. Add them to tigerduck-app/app-translation and bump the "
          f"submodule, or fix the key name.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
