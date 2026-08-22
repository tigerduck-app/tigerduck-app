#!/usr/bin/env python3
"""Fail when a Swift file's macOS membership was never decided.

The TigerDuck target builds for both iOS and macOS from one source tree, and
splits them in `project.pbxproj` with:

    EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*] = "*.swift";
    INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*] = ( ...one entry per file... );

Exclude everything, then name the files macOS gets back. Two problems follow
from that shape, and both fail quietly:

1. A new file that macOS needs is not in the allowlist, so it is silently not
   compiled there. Nothing errors until some macOS-side call site goes missing,
   which may be many commits later — or never, if the file is only reachable
   from a code path nobody exercises on the Mac.
2. The allowlist is duplicated across the Debug and Release configurations. If
   only one is updated, the app builds on your machine and breaks in the
   configuration you did not run.

Directory layout cannot express the rule — every subsystem except Models,
Platform, Theme, Clock, Widgets and Bridge is a mix of both platforms — so
this cannot be replaced with a path glob without relocating ~100 files. What
it can be is loud. Every app-target Swift file has to appear in exactly one
of: the pbxproj allowlist, or `tools/macos-excluded-sources.txt`. A new file
belongs to neither until someone says so, and that is the error.

Run manually:  python3 tools/check_macos_sources.py
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PBXPROJ = ROOT / "swift" / "TigerDuck.xcodeproj" / "project.pbxproj"
EXCLUDED_LIST = ROOT / "tools" / "macos-excluded-sources.txt"

# Sources compiled into the TigerDuck app target. It draws on two synchronized
# root groups, plus individual files pulled in from a third by a build-file
# exception set — `swift/TigerDuck/` alone is NOT the target. Other targets
# (widget/watch extensions, test bundles) build for a single SDK and are not
# split this way.
TARGET_ROOTS = ("swift/TigerDuck/", "swift/Shared/")
TARGET_EXTRA_FILES = ("swift/TigerDuckWidgets/Snapshot/WidgetSnapshotStore.swift",)

ALLOWLIST_RE = re.compile(
    r'"INCLUDED_SOURCE_FILE_NAMES\[sdk=macosx\*\]" = \(\n(.*?)\n\s*\);',
    re.S,
)


def parse_allowlists() -> list[set[str]]:
    """One set of basenames per build configuration that declares the setting.

    Entries are written both as bare filenames and as paths relative to the
    group root; `basename` normalises the two so a rename of the convention
    does not read as a membership change.
    """
    text = PBXPROJ.read_text(encoding="utf-8")
    blocks = ALLOWLIST_RE.findall(text)
    if not blocks:
        sys.exit(
            "error: no INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*] found in "
            "project.pbxproj. If the macOS split was reworked, this checker "
            "needs to be reworked with it — do not just delete it."
        )
    out = []
    for block in blocks:
        names = set()
        for line in block.strip().split("\n"):
            entry = line.strip().rstrip(",").strip('"')
            if entry:
                names.add(os.path.basename(entry))
        out.append(names)
    return out


def tracked_target_sources() -> list[str]:
    patterns = [f"{root}*.swift" for root in TARGET_ROOTS]
    listing = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", *patterns, *TARGET_EXTRA_FILES],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    missing = [f for f in TARGET_EXTRA_FILES if f not in listing]
    if missing:
        sys.exit(
            "error: TARGET_EXTRA_FILES lists files that are not tracked; the "
            "exception set in project.pbxproj has probably changed:\n"
            + "".join(f"    {f}\n" for f in missing)
        )
    return sorted(listing)


def read_excluded() -> set[str]:
    if not EXCLUDED_LIST.exists():
        sys.exit(f"error: {EXCLUDED_LIST.relative_to(ROOT)} is missing")
    names = set()
    for line in EXCLUDED_LIST.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            names.add(line)
    return names


def main() -> int:
    allowlists = parse_allowlists()
    problems: list[str] = []

    # 1. Debug and Release must agree. A file compiled in one configuration
    #    and not the other is the hardest version of this bug to see.
    first = allowlists[0]
    for i, other in enumerate(allowlists[1:], start=1):
        if other != first:
            only_a = sorted(first - other)
            only_b = sorted(other - first)
            problems.append(
                f"allowlist #{i + 1} disagrees with #1 — the Debug and Release "
                f"copies have drifted apart.\n"
                + "".join(f"    only in #1: {n}\n" for n in only_a)
                + "".join(f"    only in #{i + 1}: {n}\n" for n in only_b)
            )

    allowed = first
    excluded = read_excluded()
    sources = tracked_target_sources()
    basenames = {os.path.basename(f) for f in sources}

    # 2. Every source is either compiled on macOS or deliberately not.
    undecided = [
        f for f in sources
        if os.path.basename(f) not in allowed
        and os.path.basename(f) not in excluded
    ]
    if undecided:
        problems.append(
            "these files are in neither the macOS allowlist nor the "
            "deliberate-exclusion list, so nobody has decided whether macOS "
            "compiles them:\n"
            + "".join(f"    {f}\n" for f in undecided)
            + "  Add each to the INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*] "
            "arrays (BOTH of them) if macOS needs it, or to\n"
            "  tools/macos-excluded-sources.txt with a reason if it is "
            "iOS-only."
        )

    # 3. Claiming both is contradictory and means one of them is a leftover.
    both = sorted(basenames & allowed & excluded)
    if both:
        problems.append(
            "these files are listed as macOS-included AND deliberately "
            "excluded:\n" + "".join(f"    {n}\n" for n in both)
        )

    # 4. Names that no longer match a file. Harmless to the build, but they
    #    are what makes the list untrustworthy to read.
    for label, names in (("allowlist", allowed), ("exclusion list", excluded)):
        stale = sorted(n for n in names if n not in basenames)
        if stale:
            problems.append(
                f"{label} names files that no longer exist:\n"
                + "".join(f"    {n}\n" for n in stale)
            )

    if problems:
        print("error: macOS source membership is out of sync\n", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        return 1

    print(
        f"OK {len(sources)} app-target sources: "
        f"{len(sources) - len(undecided) - len(basenames & excluded)} macOS, "
        f"{len(basenames & excluded)} iOS-only, "
        f"{len(allowlists)} allowlists in agreement"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
