#!/usr/bin/env python3
"""Keep the macOS build's source list generated from one place.

The TigerDuck target builds for both iOS and macOS from one source tree, and
splits them in `project.pbxproj` with:

    EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*] = "*.swift";
    INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*] = ( ...one entry per file... );

Exclude everything, then name the files macOS gets back. The two arrays, one
in Debug and one in Release, are not edited by hand: they are every
app-target Swift file minus `tools/macos-excluded-sources.txt`, sorted by
base name. `--write` rewrites them from that; the default mode fails when
they differ from it, so a new file reaches the Mac build or the exclusion
list by a decision rather than by being forgotten in one configuration.

Xcode matches the entries by file name, so two app-target Swift files with
one base name cannot be told apart there, and that fails too.

Run manually:  python3 tools/check_macos_sources.py [--write]
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PBXPROJ = ROOT / "swift" / "TigerDuck.xcodeproj" / "project.pbxproj"
EXCLUDED_LIST = ROOT / "tools" / "macos-excluded-sources.txt"

# Sources compiled into the TigerDuck app target. It draws on two synchronized
# root groups, plus individual files pulled in from a third by a build-file
# exception set, so `swift/TigerDuck/` alone is not the target. Other targets
# (widget and watch extensions, test bundles) build for one SDK and are not
# split this way.
TARGET_ROOTS = ("swift/TigerDuck/", "swift/Shared/")
TARGET_ROOT_FOLDERS = {r.split("/")[1] for r in TARGET_ROOTS}

# Files pulled into the app target from another synchronized group by a
# membership exception. Parsed rather than hardcoded, so the list cannot go
# stale the way a hand-kept one does.
EXCEPTION_RE = re.compile(
    r'/\* Exceptions for "([^"]+)" folder in "TigerDuck" target \*/ = \{'
    r".*?membershipExceptions = \((.*?)\n\s*\);",
    re.S,
)

ALLOWLIST_RE = re.compile(
    r'(?P<head>"INCLUDED_SOURCE_FILE_NAMES\[sdk=macosx\*\]" = \(\n)(?P<body>.*?)(?P<tail>\n(?P<indent>\s*)\);)',
    re.S,
)

WRITE_HINT = "run `python3 tools/check_macos_sources.py --write`"


def parse_allowlists(text: str) -> list[list[str]]:
    """The entries of each INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*] array, in order."""
    blocks = ALLOWLIST_RE.findall(text)
    if not blocks:
        sys.exit(
            "error: no INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*] found in "
            "project.pbxproj. If the macOS split was reworked, rework this "
            "checker with it instead of deleting it."
        )
    out = []
    for block in blocks:
        names = []
        for line in block[1].strip().split("\n"):
            entry = line.strip().rstrip(",").strip('"')
            if entry:
                names.append(entry)
        out.append(names)
    return out


def target_extra_files(text: str) -> list[str]:
    """Swift files the app target picks up from a non-root synchronized group.

    An exception set on a group's own target lists files to leave out; on any
    other group it lists files to pull in. Only the latter add sources, so
    groups that are already target roots are skipped.
    """
    extra = []
    for folder, block in EXCEPTION_RE.findall(text):
        if folder in TARGET_ROOT_FOLDERS:
            continue
        for line in block.strip().split("\n"):
            entry = line.strip().rstrip(",").strip('"')
            if entry.endswith(".swift"):
                extra.append(f"swift/{folder}/{entry}")
    return sorted(extra)


def tracked_target_sources(text: str, root: Path = ROOT) -> list[str]:
    extras = target_extra_files(text)
    patterns = [f"{r}*.swift" for r in TARGET_ROOTS]
    listing = subprocess.run(
        ["git", "-C", str(root), "ls-files", *patterns, *extras],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split("\n")
    listing = [f for f in listing if f]
    missing = [f for f in extras if f not in listing]
    if missing:
        sys.exit(
            "error: project.pbxproj pulls these files into the app target "
            "through a membership exception, but git does not track them:\n"
            + "".join(f"    {f}\n" for f in missing)
        )
    return sorted(listing)


def read_excluded(path: Path = EXCLUDED_LIST) -> set[str]:
    if not path.exists():
        sys.exit(f"error: {path} is missing")
    names = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            names.add(line)
    return names


def expected_allowlist(sources: list[str], excluded: set[str]) -> list[str]:
    return sorted({os.path.basename(f) for f in sources} - excluded, key=str.lower)


def pbx_quote(name: str) -> str:
    return name if re.fullmatch(r"[A-Za-z0-9_./]+", name) else f'"{name}"'


def rewrite(text: str, names: list[str]) -> str:
    def body(match: re.Match[str]) -> str:
        indent = match.group("indent") + "\t"
        lines = "\n".join(f"{indent}{pbx_quote(n)}," for n in names)
        return match.group("head") + lines + match.group("tail")

    return ALLOWLIST_RE.sub(body, text)


def problems(text: str, sources: list[str], excluded: set[str]) -> list[str]:
    found: list[str] = []
    counts = Counter(os.path.basename(f) for f in sources)
    shared = sorted(n for n, c in counts.items() if c > 1)
    if shared:
        found.append(
            "these base names belong to more than one app-target Swift file, which the "
            "macOS arrays cannot tell apart; rename one of each:\n"
            + "".join(
                f"    {n}: {', '.join(f for f in sources if os.path.basename(f) == n)}\n"
                for n in shared
            )
        )
    stale = sorted(excluded - set(counts))
    if stale:
        found.append(
            "tools/macos-excluded-sources.txt names files that no longer exist:\n"
            + "".join(f"    {n}\n" for n in stale)
        )
    expected = expected_allowlist(sources, excluded)
    for i, names in enumerate(parse_allowlists(text), start=1):
        if names == expected:
            continue
        have, want = set(names), set(expected)
        lines = [f"    missing: {n}\n" for n in sorted(want - have)]
        lines += [f"    extra: {n}\n" for n in sorted(have - want)]
        if not lines:
            lines = ["    entries are not sorted\n"]
        found.append(
            f"INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*] array #{i} is not every app-target "
            f"Swift file minus tools/macos-excluded-sources.txt; {WRITE_HINT}, or list an "
            "iOS-only file in the exclusion list:\n" + "".join(lines)
        )
    return found


def main(argv: list[str]) -> int:
    text = PBXPROJ.read_text(encoding="utf-8")
    excluded = read_excluded()
    sources = tracked_target_sources(text)
    if "--write" in argv:
        new = rewrite(text, expected_allowlist(sources, excluded))
        if new != text:
            PBXPROJ.write_text(new, encoding="utf-8")
            text = new
            print("wrote the macOS arrays in project.pbxproj")
    found = problems(text, sources, excluded)
    if found:
        print("error: macOS source membership is out of sync\n", file=sys.stderr)
        for p in found:
            print(f"  {p}", file=sys.stderr)
        return 1
    macos = len(expected_allowlist(sources, excluded))
    print(
        f"OK {len(sources)} app-target sources: {macos} macOS, "
        f"{len(sources) - macos} iOS-only, {len(parse_allowlists(text))} arrays generated"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
