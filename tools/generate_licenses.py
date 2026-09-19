#!/usr/bin/env python3
"""Write swift/TigerDuck/licenses.json, the data behind Settings → Others →
Open-source licences.

The page lists TigerDuck's own licence (the repository's LICENSE) and every
Swift package the app links, each with its licence file verbatim — copyright
lines included, which is what MIT and BSD ask to be reproduced — plus any
NOTICE file it ships. There is no Swift Package Manager equivalent of
Android's AboutLibraries plugin, so this reads the package checkouts itself.

Packages come from Package.resolved, plus local packages the project
references by path (those never appear in Package.resolved). BUILD_ONLY
names the ones left out on purpose, with the reason.

Regenerate after adding, removing or updating a package:

    python3 tools/generate_licenses.py                  # resolves packages into a temp dir first
    python3 tools/generate_licenses.py --checkouts DIR  # reuse DerivedData/*/SourcePackages/checkouts

Check that licenses.json still matches Package.resolved and LICENSE, offline
(what CI runs):

    python3 tools/generate_licenses.py --check
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "swift" / "TigerDuck.xcodeproj"
RESOLVED = PROJECT / "project.xcworkspace" / "xcshareddata" / "swiftpm" / "Package.resolved"
PBXPROJ = PROJECT / "project.pbxproj"
OUTPUT = ROOT / "swift" / "TigerDuck" / "licenses.json"
APP_LICENSE = ROOT / "LICENSE"
APP_LICENSE_NAME = "GNU Affero General Public License v3.0"

# Resolved, but nothing from them ends up in the app.
BUILD_ONLY = {
    "swift-syntax": "only Defaults' macros use it, and macros run inside the compiler",
}

# Where reading the licence file's first block would name only part of it.
LICENSE_OVERRIDES = {
    # COPYING opens with cmark's own BSD-2-Clause, then the MIT terms of the
    # houdini, buffer and utf8 code it includes.
    "swift-cmark": "BSD-2-Clause AND MIT",
}

LICENSE_FILE = re.compile(r"^(licen[cs]e|copying)(\.(md|txt))?$", re.IGNORECASE)
NOTICE_FILE = re.compile(r"^(notice|third_party_notices)(\.(md|txt))?$", re.IGNORECASE)
# A copyright line as written by the holder, not the Apache appendix's
# "Copyright [yyyy] [name of copyright owner]" template or the licence's own
# prose about "the above copyright notice".
COPYRIGHT_LINE = re.compile(r"^\s*(copyright\s*(\(c\)|©|\d)|\(c\)\s*\d|©)", re.IGNORECASE)


def resolved_pins() -> list[dict]:
    return json.loads(RESOLVED.read_text())["pins"]


def local_packages() -> list[Path]:
    text = PBXPROJ.read_text()
    paths = re.findall(
        r"isa = XCLocalSwiftPackageReference;\s*relativePath = \"?([^\";]+)\"?;", text
    )
    return [(PROJECT.parent / p).resolve() for p in paths]


def repo_name(location: str) -> str:
    return location.rstrip("/").split("/")[-1].removesuffix(".git")


def detect_license(text: str) -> str:
    if "Apache License" in text and "Version 2.0" in text:
        return "Apache-2.0"
    if "Permission is hereby granted, free of charge" in text:
        return "MIT"
    if "Redistribution and use in source and binary forms" in text:
        return "BSD-3-Clause" if "Neither the name" in text else "BSD-2-Clause"
    raise SystemExit("error: unrecognised licence text; add the package to LICENSE_OVERRIDES")


def package_entry(identity: str, name: str, version: str | None, url: str | None, checkout: Path) -> dict:
    files = sorted(p for p in checkout.iterdir() if p.is_file())
    licenses = [p for p in files if LICENSE_FILE.match(p.name)]
    notices = [p for p in files if NOTICE_FILE.match(p.name)]
    if not licenses:
        raise SystemExit(f"error: {name} has no LICENSE or COPYING file in {checkout}")
    texts = [{"file": p.name, "text": p.read_text().strip() + "\n"} for p in licenses + notices]
    main = texts[0]["text"]
    return {
        "identity": identity,
        "name": name,
        "version": version,
        "url": url,
        "license": LICENSE_OVERRIDES.get(identity) or detect_license(main),
        "copyright": list(dict.fromkeys(line.strip() for line in main.splitlines() if COPYRIGHT_LINE.match(line))),
        "texts": texts,
    }


def resolve_checkouts(into: Path) -> Path:
    subprocess.run(
        [
            "xcodebuild", "-resolvePackageDependencies",
            "-project", str(PROJECT),
            "-scheme", "TigerDuck",
            "-clonedSourcePackagesDirPath", str(into),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return into / "checkouts"


def generate(checkouts: Path) -> dict:
    packages = []
    for pin in resolved_pins():
        identity = pin["identity"]
        if identity in BUILD_ONLY:
            continue
        name = repo_name(pin["location"])
        checkout = checkouts / name
        if not checkout.is_dir():
            raise SystemExit(f"error: no checkout for {identity} at {checkout}")
        packages.append(package_entry(
            identity, name, pin["state"].get("version"), pin["location"].removesuffix(".git"), checkout,
        ))
    for path in local_packages():
        packages.append(package_entry(path.name.lower(), path.name, None, None, path))
    packages.sort(key=lambda p: p["name"].lower())
    return {
        "app": {"license": APP_LICENSE_NAME, "text": APP_LICENSE.read_text()},
        "packages": packages,
    }


def check() -> int:
    if not OUTPUT.exists():
        print(f"error: {OUTPUT.relative_to(ROOT)} is missing", file=sys.stderr)
        return 1
    listed = {p["identity"]: p.get("version") for p in json.loads(OUTPUT.read_text())["packages"]}
    expected = {
        pin["identity"]: pin["state"].get("version")
        for pin in resolved_pins()
        if pin["identity"] not in BUILD_ONLY
    }
    expected.update({path.name.lower(): None for path in local_packages()})
    problems = []
    for identity in sorted(expected.keys() - listed.keys()):
        problems.append(f"  {identity} is linked but not listed")
    for identity in sorted(listed.keys() - expected.keys()):
        problems.append(f"  {identity} is listed but no longer linked")
    for identity in sorted(expected.keys() & listed.keys()):
        if expected[identity] != listed[identity]:
            problems.append(f"  {identity} is {expected[identity]}, listed as {listed[identity]}")
    if json.loads(OUTPUT.read_text())["app"]["text"] != APP_LICENSE.read_text():
        problems.append("  LICENSE changed since the list was generated")
    if problems:
        print("error: licenses.json is out of date:", file=sys.stderr)
        print("\n".join(problems), file=sys.stderr)
        print("Run: python3 tools/generate_licenses.py", file=sys.stderr)
        return 1
    print(f"OK {len(listed)} packages listed, {len(BUILD_ONLY)} build-only left out")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--checkouts", type=Path, help="existing SourcePackages/checkouts directory")
    parser.add_argument("--check", action="store_true", help="verify licenses.json, without network")
    args = parser.parse_args()
    if args.check:
        return check()
    if args.checkouts:
        data = generate(args.checkouts)
    else:
        with tempfile.TemporaryDirectory() as tmp:
            data = generate(resolve_checkouts(Path(tmp)))
    OUTPUT.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    print(f"wrote {OUTPUT.relative_to(ROOT)}: {len(data['packages'])} packages")
    return check()


if __name__ == "__main__":
    sys.exit(main())
