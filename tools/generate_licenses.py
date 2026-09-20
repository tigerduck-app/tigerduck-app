#!/usr/bin/env python3
"""Write swift/TigerDuck/licenses.json, the data behind Settings → Others →
Open-source licences.

The page lists TigerDuck's own licence (the repository's LICENSE) and every
Swift package the app links, each with its licence file verbatim — copyright
lines included, which is what MIT and BSD ask to be reproduced — plus any
NOTICE file it ships. There is no Swift Package Manager equivalent of
Android's AboutLibraries plugin, so this reads the package checkouts itself.

Packages come from Package.resolved, plus local packages the project
references by path (those never appear in Package.resolved, and
LOCAL_PACKAGE_NOTES says what to write where they have no version to show).
BUILD_ONLY names the ones left out on purpose, with the reason. BUNDLED
names material that ships inside the app bundle without being a package at
all, which no dependency graph would ever mention.

One list covers every target. Only the main app target has a non-empty
packageProductDependencies — the watch app, the widgets and the Live
Activity extension link no packages of their own — so the iPhone's page is
already the whole story. Check that again if a watch-only dependency is
ever added.

Regenerate after adding, removing or updating a package:

    python3 tools/generate_licenses.py                  # resolves packages into a temp dir first
    python3 tools/generate_licenses.py --checkouts DIR  # reuse DerivedData/*/SourcePackages/checkouts

The first form shells out to `xcodebuild -resolvePackageDependencies`, which
writes back to the project's own Package.resolved — the tracked file, not a
copy inside the temp directory — so regenerating the list can bump pins as a
side effect. Read `git diff` on Package.resolved afterwards and keep or
revert that separately from the list.

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

# Ships inside the app bundle, but is not a Swift package, so
# Package.resolved has nothing to say about it. Its licence is its own — the
# app being AGPL does not cover data published separately under MIT.
BUNDLED = [
    {
        "identity": "name-abbr",
        "name": "name-abbr",
        "path": ROOT / "name-abbr",
        "url": "https://github.com/tigerduck-app/name-abbr",
        "firstParty": True,
        "note": (
            "Course and classroom abbreviation tables, shipped as "
            "class-name-abbr.json and classroom-name-abbr.json. Published "
            "separately from the app and under MIT rather than the app's AGPL."
        ),
    },
]

# Swift packages the project references by path rather than resolving. They
# live in this repository, so Package.resolved never names them and there is
# no version to show — and an entry without a version has to say why it ships
# instead (LicenseCatalogTests checks that). Keyed by directory name;
# LOCAL_PACKAGE_NOTE covers the ones not named here.
LOCAL_PACKAGE_NOTES: dict[str, str] = {}
LOCAL_PACKAGE_NOTE = (
    "A Swift package kept in this repository and built from source rather "
    "than resolved from a release, so there is no version to name."
)

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
    return json.loads(RESOLVED.read_text(encoding="utf-8"))["pins"]


def local_packages() -> list[Path]:
    text = PBXPROJ.read_text(encoding="utf-8")
    paths = re.findall(
        r"isa = XCLocalSwiftPackageReference;\s*relativePath = \"?([^\";]+)\"?;", text
    )
    return [(PROJECT.parent / p).resolve() for p in paths]


def repo_name(location: str) -> str:
    return location.rstrip("/").split("/")[-1].removesuffix(".git")


def license_text(path: Path, owner: str) -> str:
    """A licence or notice file, which is UTF-8 in practice. Say whose it is
    when it is not: a bare UnicodeDecodeError names the codec and a byte
    offset, and nothing that would let you find the package."""
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        raise SystemExit(f"error: {owner}'s {path.name} is not UTF-8 ({error})")


def brief(value: object) -> str:
    """Notes run to a paragraph, and a failure line reads better with their
    opening words than with the whole thing."""
    text = str(value)
    return text if len(text) <= 60 else text[:59] + "…"


def detect_license(identity: str, text: str) -> str:
    if "Apache License" in text and "Version 2.0" in text:
        return "Apache-2.0"
    if "Permission is hereby granted, free of charge" in text:
        return "MIT"
    if "Redistribution and use in source and binary forms" in text:
        return "BSD-3-Clause" if "Neither the name" in text else "BSD-2-Clause"
    raise SystemExit(f"error: unrecognised licence text for {identity}; add it to LICENSE_OVERRIDES")


def verify_revision(identity: str, checkout: Path, pinned: str | None) -> None:
    """A checkout has to be at the revision Package.resolved pins for it.

    --checkouts reuses a directory something else resolved, which may predate
    the pin it is read against. The version written into the list comes from
    Package.resolved while the licence text comes from the checkout, so a
    stale one prints this version's number over the last version's licence —
    and --check compares identity and version, which both look right, so
    nothing downstream would ever notice.
    """
    if not pinned:
        raise SystemExit(
            f"error: Package.resolved pins no revision for {identity}, so there is nothing "
            f"to check {checkout} against"
        )
    try:
        head = subprocess.run(
            ["git", "-C", str(checkout), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
        )
    except OSError as error:  # no git on PATH
        raise SystemExit(f"error: cannot run git to check {identity}'s checkout: {error}")
    if head.returncode != 0:
        raise SystemExit(
            f"error: cannot tell which revision {checkout} is at "
            f"({head.stderr.strip() or 'git rev-parse HEAD failed'}). Swift Package Manager "
            "leaves its checkouts as git working copies; one that is not cannot be matched "
            "against the pin, so this stops rather than read a licence it cannot place."
        )
    if head.stdout.strip() != pinned:
        raise SystemExit(
            f"error: {identity} is checked out at {head.stdout.strip()}, but Package.resolved "
            f"pins {pinned}, so its licence text would be read from the wrong version. "
            "Re-resolve that directory, or drop --checkouts to resolve into a temp one."
        )


def within(path: Path, root: Path) -> bool:
    """Whether `path` really lives under `root`, symlinks followed.

    A package may legitimately symlink LICENSE to LICENSE.md, so the link
    itself is fine; what is not is a link whose target leaves the checkout.
    Everything matched here is copied verbatim into a file that is committed
    and shipped, and `is_file()` and `read_text()` both follow links, so a
    dependency could otherwise name any readable UTF-8 file on the machine
    that generates the list and have its contents published. Pinning the
    revision does not help: the link can belong to the pinned commit.
    """
    try:
        return path.resolve(strict=True).is_relative_to(root.resolve(strict=True))
    except (OSError, RuntimeError):
        return False


def package_entry(
    identity: str,
    name: str,
    version: str | None,
    url: str | None,
    checkout: Path,
    note: str | None = None,
    first_party: bool = False,
    revision: str | None = None,
) -> dict:
    files = sorted(p for p in checkout.iterdir() if p.is_file())
    licenses = [p for p in files if LICENSE_FILE.match(p.name)]
    notices = [p for p in files if NOTICE_FILE.match(p.name)]
    escaping = [p for p in licenses + notices if not within(p, checkout)]
    if escaping:
        raise SystemExit(
            f"error: {name}'s {', '.join(p.name for p in escaping)} resolves outside "
            f"{checkout}; refusing to copy a file from beyond the package into the list"
        )
    if not licenses:
        raise SystemExit(f"error: {name} has no LICENSE or COPYING file in {checkout}")
    texts = [{"file": p.name, "text": license_text(p, name).strip() + "\n"} for p in licenses + notices]
    main = texts[0]["text"]
    return {
        "identity": identity,
        "name": name,
        "version": version,
        # The version alone cannot date the list: a pin moved to a new
        # revision at the same version, or pinned to a branch or a bare
        # revision and so carrying no version at all, would compare equal
        # forever while the licence text went stale.
        "revision": revision,
        "url": url,
        "license": LICENSE_OVERRIDES.get(identity) or detect_license(identity, main),
        "copyright": list(dict.fromkeys(line.strip() for line in main.splitlines() if COPYRIGHT_LINE.match(line))),
        "note": note,
        # TigerDuck's own, published separately: listed beside the app
        # rather than under third parties, since it is neither.
        "firstParty": first_party,
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
        verify_revision(identity, checkout, pin["state"].get("revision"))
        packages.append(package_entry(
            identity, name, pin["state"].get("version"), pin["location"].removesuffix(".git"), checkout,
            revision=pin["state"].get("revision"),
        ))
    for path in local_packages():
        if not path.is_dir():
            raise SystemExit(
                f"error: the project references a local package at {path}, which is not there"
            )
        packages.append(package_entry(
            path.name.lower(), path.name, None, None, path,
            LOCAL_PACKAGE_NOTES.get(path.name, LOCAL_PACKAGE_NOTE),
        ))
    for bundled in BUNDLED:
        path = bundled["path"]
        if not path.is_dir():
            raise SystemExit(
                f"error: {bundled['identity']} is not checked out at {path}. "
                "Run: git submodule update --init"
            )
        packages.append(package_entry(
            bundled["identity"], bundled["name"], None, bundled["url"], path,
            bundled["note"], bundled["firstParty"],
        ))
    packages.sort(key=lambda p: p["name"].lower())
    return {
        "app": {"license": APP_LICENSE_NAME, "text": APP_LICENSE.read_text(encoding="utf-8")},
        "packages": packages,
    }


def table_fields() -> list[tuple[str, dict]]:
    """What the tables above, rather than a checkout, decide about an entry.
    Edit one without regenerating and the page keeps showing the old text, so
    --check reads these back out of the list."""
    fields = [
        (
            bundled["identity"],
            {
                "name": bundled["name"],
                "url": bundled["url"],
                "note": bundled["note"],
                "firstParty": bundled["firstParty"],
            },
        )
        for bundled in BUNDLED
    ]
    fields += [
        (
            path.name.lower(),
            {
                "name": path.name,
                "url": None,
                "note": LOCAL_PACKAGE_NOTES.get(path.name, LOCAL_PACKAGE_NOTE),
                "firstParty": False,
            },
        )
        for path in local_packages()
    ]
    return fields


def check() -> int:
    if not OUTPUT.exists():
        print(f"error: {OUTPUT.relative_to(ROOT)} is missing", file=sys.stderr)
        return 1
    listing = json.loads(OUTPUT.read_text(encoding="utf-8"))
    listed = {p["identity"]: p for p in listing["packages"]}
    expected = {
        pin["identity"]: (pin["state"].get("version"), pin["state"].get("revision"))
        for pin in resolved_pins()
        if pin["identity"] not in BUILD_ONLY
    }
    expected.update({path.name.lower(): (None, None) for path in local_packages()})
    expected.update({bundled["identity"]: (None, None) for bundled in BUNDLED})
    problems = []
    for identity in sorted(expected.keys() - listed.keys()):
        problems.append(f"  {identity} is linked but not listed")
    for identity in sorted(listed.keys() - expected.keys()):
        problems.append(f"  {identity} is listed but no longer linked")
    for identity in sorted(expected.keys() & listed.keys()):
        version, revision = expected[identity]
        if version != listed[identity].get("version"):
            problems.append(
                f"  {identity} is {version}, listed as {listed[identity].get('version')}"
            )
        # The revision as well as the version, because a pin can move without
        # the version moving — and a pin to a branch or a bare revision has no
        # version at all, so version alone would compare None to None however
        # far the licence text had drifted.
        elif revision != listed[identity].get("revision"):
            problems.append(
                f"  {identity} is at {brief(revision)}, listed at "
                f"{brief(listed[identity].get('revision'))}"
            )
    # Fields a table decides rather than a checkout. Identity and version both
    # still look right after a table is edited, so without this a note, a URL
    # or a first-party flag can drift out of the page unnoticed.
    for identity, fields in table_fields():
        entry = listed.get(identity)
        if entry is None:
            continue  # already reported above as linked but not listed
        for field, value in fields.items():
            if entry.get(field) != value:
                problems.append(
                    f"  {identity}'s {field} is {brief(value)}, listed as {brief(entry.get(field))}"
                )
    # The licence name is LICENSE_OVERRIDES' where it names one and whatever
    # detect_license reads out of the text otherwise — and the text is in the
    # list, so both halves can be worked out again here without a checkout.
    # That catches an override added, changed or removed without regenerating.
    # It reads the listed text, so it says nothing about a text gone stale;
    # that is what the file comparisons below are for.
    for identity, entry in sorted(listed.items()):
        license_name = LICENSE_OVERRIDES.get(identity) or detect_license(identity, entry["texts"][0]["text"])
        if entry.get("license") != license_name:
            problems.append(f"  {identity} is {license_name}, listed as {entry.get('license')}")
    listed_texts = {identity: entry["texts"][0]["text"] for identity, entry in listed.items()}
    if listing["app"]["text"] != APP_LICENSE.read_text(encoding="utf-8"):
        problems.append("  LICENSE changed since the list was generated")
    # Compare only what is on disk: a working copy without its submodules can
    # still run the rest of the check. CI checks them out so that this
    # comparison does happen there — a pin moved to a commit whose LICENSE
    # changed is exactly the kind of staleness nothing else here would see —
    # and a skip says so rather than passing for a reason nobody reads.
    compared = 0
    for bundled in BUNDLED:
        license_file = bundled["path"] / "LICENSE"
        if not license_file.is_file():
            print(
                f"note: {bundled['identity']}'s licence text was not compared, "
                f"{license_file.relative_to(ROOT)} is not checked out "
                "(git submodule update --init)",
                file=sys.stderr,
            )
            continue
        compared += 1
        if listed_texts.get(bundled["identity"]) != license_text(license_file, bundled["identity"]).strip() + "\n":
            problems.append(f"  {bundled['identity']}'s LICENSE changed since the list was generated")
    if problems:
        print("error: licenses.json is out of date:", file=sys.stderr)
        print("\n".join(problems), file=sys.stderr)
        print("Run: python3 tools/generate_licenses.py", file=sys.stderr)
        return 1
    print(
        f"OK {len(listed)} packages listed, {len(BUILD_ONLY)} build-only left out; "
        "versions, licence names and the app's LICENSE verified, "
        f"{compared} of {len(BUNDLED)} bundled licence texts compared"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--checkouts", type=Path, help="existing SourcePackages/checkouts directory")
    parser.add_argument("--check", action="store_true", help="verify licenses.json, without network")
    args = parser.parse_args()
    if args.check:
        if args.checkouts:
            parser.error("--check reads only what is committed, so --checkouts has nothing to add")
        return check()
    if args.checkouts:
        data = generate(args.checkouts)
    else:
        with tempfile.TemporaryDirectory() as tmp:
            data = generate(resolve_checkouts(Path(tmp)))
    OUTPUT.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(ROOT)}: {len(data['packages'])} packages")
    return check()


if __name__ == "__main__":
    sys.exit(main())
