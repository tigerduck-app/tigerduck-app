#!/usr/bin/env python3
"""Fail when a shipping target calls a required-reason API its privacy manifest does not declare.

App Store Connect rejects a build that calls a required-reason API without a reason for its
category in the PrivacyInfo.xcprivacy of the bundle that holds the code
(https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api),
and each app and app extension is a bundle of its own. For every application and app-extension
target in `project.pbxproj` this works out the files the target builds the way Xcode does: the
files in its synchronized folders minus those their exception sets leave out, plus the files
other folders' exception sets pull in, plus the sources of a local package it links that ships
no manifest of its own. It fails when a target builds no PrivacyInfo.xcprivacy or more than one,
or when its Swift code matches a pattern in CATEGORIES and the manifest does not declare that
category, or declares a reason Apple does not list for it.

Remote packages are not scanned, since CI does not resolve them. Defaults, swift-nio's NIOPosix
and swift-nio-ssl ship their own manifests; Valet, SwiftSoup, swift-markdown-ui and the rest call
none of these APIs. Check a new or updated remote package by hand.

Run manually:  python3 tools/check_privacy_manifests.py
"""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path
from xml.parsers.expat import ExpatError

ROOT = Path(__file__).resolve().parents[1]
PROJECT = Path("swift/TigerDuck.xcodeproj/project.pbxproj")
MANIFEST = "PrivacyInfo.xcprivacy"
SHIPPING = {"com.apple.product-type.application", "com.apple.product-type.app-extension"}

# One pattern per category, from the API lists on Apple's page for NSPrivacyAccessedAPIType, with
# the reasons that page allows. `@AppStorage` is SwiftUI's wrapper around UserDefaults.
# shortcut: getattrlist also reads disk space; declare DiskSpace by hand if a call does.
CATEGORIES = {
    "NSPrivacyAccessedAPICategoryUserDefaults": (
        r"\bUserDefaults\b|@AppStorage\b",
        {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
    ),
    "NSPrivacyAccessedAPICategoryFileTimestamp": (
        r"\.(creationDate|modificationDate)(Key)?\b|\b(contentModificationDate|contentAccessDate)(Key)?\b"
        r"|\bNS(FileCreationDate|FileModificationDate|URLContentModificationDateKey|URLCreationDateKey)\b"
        r"|\bfileModificationDate\b|\b[fl]?stat(at)?\(|\bf?getattrlist(at|bulk)?\(",
        {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    ),
    "NSPrivacyAccessedAPICategorySystemBootTime": (
        r"\bsystemUptime\b|\bmach_absolute_time\b",
        {"35F9.1", "8FFB.1", "3D61.1"},
    ),
    "NSPrivacyAccessedAPICategoryDiskSpace": (
        r"\bvolume(Available|Total)Capacity\w*|\b(system|NSFileSystem)(Free)?Size\b|\bf?statv?fs\(",
        {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    ),
    "NSPrivacyAccessedAPICategoryActiveKeyboards": (
        r"\bactiveInputModes\b",
        {"3EC4.1", "54BD.1"},
    ),
}

OBJECT_RE = re.compile(r"^\t\t(\w{24}) (?:/\*[^\n]*?\*/ )?= \{\n(.*?)^\t\t\};", re.M | re.S)
COMMENT_RE = re.compile(r"/\*.*?\*/")
LINE_COMMENT_RE = re.compile(r"(^|\s)//.*$", re.M)
LIBRARY_RE = re.compile(r"\.library\(\s*name:\s*\"([^\"]+)\"")


def objects(text: str) -> dict[str, str]:
    return dict(OBJECT_RE.findall(text))


def unquote(value: str) -> str:
    value = COMMENT_RE.sub("", value).strip()
    return value[1:-1].replace('\\"', '"') if value.startswith('"') else value


def field(body: str, key: str) -> str | None:
    match = re.search(rf"^\t\t\t{key} = (.*?);$", body, re.M)
    return unquote(match.group(1)) if match else None


def items(body: str, key: str) -> list[str]:
    match = re.search(rf"^\t\t\t{key} = \((.*?)\);", body, re.M | re.S)
    if not match:
        return []
    return [unquote(line.strip().rstrip(",")) for line in match.group(1).splitlines() if line.strip()]


def listed(path: str, entries: list[str]) -> bool:
    return any(path == entry or path.startswith(entry + "/") for entry in entries)


def target_files(objs: dict[str, str], target_id: str, swift_dir: Path) -> list[Path]:
    """Every file a target builds from the synchronized folders, as Xcode decides membership.

    An exception set on one of the target's own folders lists files it leaves out; on any other
    folder it lists the only files the target takes from it.
    """
    own = set(items(objs[target_id], "fileSystemSynchronizedGroups"))
    files = []
    for group_id, body in objs.items():
        if field(body, "isa") != "PBXFileSystemSynchronizedRootGroup":
            continue
        folder = swift_dir / field(body, "path")
        entries = [entry for set_id in items(body, "exceptions")
                   if field(objs[set_id], "target") == target_id
                   for entry in items(objs[set_id], "membershipExceptions")]
        if group_id not in own and not entries:
            continue
        for path in sorted(p for p in folder.rglob("*") if p.is_file()):
            inside = listed(path.relative_to(folder).as_posix(), entries)
            if inside != (group_id in own):
                files.append(path)
    return files


def package_sources(objs: dict[str, str], target_id: str, swift_dir: Path) -> list[Path]:
    """Swift sources of the local packages a target links, unless a package has its own manifest."""
    products = {field(objs[dep], "productName") for dep in items(objs[target_id], "packageProductDependencies")}
    sources = []
    for body in objs.values():
        if field(body, "isa") != "XCLocalSwiftPackageReference":
            continue
        package = swift_dir / field(body, "relativePath")
        if not products & set(LIBRARY_RE.findall((package / "Package.swift").read_text(encoding="utf-8"))):
            continue
        if not any((package / "Sources").rglob(MANIFEST)):
            sources += sorted((package / "Sources").rglob("*.swift"))
    return sources


def used_categories(sources: list[Path]) -> dict[str, Path]:
    """The first file that uses each category, with whole-line and trailing comments ignored."""
    found: dict[str, Path] = {}
    for path in sources:
        code = LINE_COMMENT_RE.sub("", path.read_text(encoding="utf-8"))
        for category, (pattern, _) in CATEGORIES.items():
            if category not in found and re.search(pattern, code):
                found[category] = path
    return found


def manifest_problems(name: str, manifest: Path, used: dict[str, Path], root: Path) -> list[str]:
    try:
        plist = plistlib.loads(manifest.read_bytes())
    except (plistlib.InvalidFileException, ValueError, ExpatError) as error:
        return [f"{name}: {manifest.relative_to(root)} is not a valid property list: {error}"]
    declared: dict[str, list[str]] = {}
    for entry in plist.get("NSPrivacyAccessedAPITypes", []):
        declared[entry.get("NSPrivacyAccessedAPIType", "")] = entry.get("NSPrivacyAccessedAPITypeReasons", [])
    problems = []
    for category, reasons in declared.items():
        allowed = CATEGORIES.get(category, (None, set()))[1]
        if category not in CATEGORIES:
            problems.append(f"{name}: declares unknown category `{category}`")
        elif not reasons or set(reasons) - allowed:
            problems.append(f"{name}: `{category}` needs one or more of {sorted(allowed)}, not {reasons}")
    for category, path in used.items():
        if category not in declared:
            problems.append(f"{name}: {path.relative_to(root)} uses `{category}`, "
                            f"which {manifest.relative_to(root)} does not declare")
    return problems


def problems(root: Path = ROOT) -> list[str]:
    objs = objects((root / PROJECT).read_text(encoding="utf-8"))
    swift_dir = (root / PROJECT).parent.parent
    found = []
    for target_id, body in objs.items():
        if field(body, "isa") != "PBXNativeTarget" or field(body, "productType") not in SHIPPING:
            continue
        name = field(body, "name")
        files = target_files(objs, target_id, swift_dir)
        manifests = [path for path in files if path.name == MANIFEST]
        if len(manifests) != 1:
            found.append(f"{name}: builds {len(manifests)} {MANIFEST} files, needs one: "
                         + (", ".join(str(p.relative_to(root)) for p in manifests) or "none"))
            continue
        sources = [path for path in files if path.suffix == ".swift"] + package_sources(objs, target_id, swift_dir)
        found += manifest_problems(name, manifests[0], used_categories(sources), root)
    return found


def main() -> int:
    found = problems()
    if found:
        print("error: privacy manifests are out of date\n", file=sys.stderr)
        for problem in found:
            print(f"  {problem}", file=sys.stderr)
        return 1
    print("OK every app and extension target declares the required-reason APIs it uses")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
