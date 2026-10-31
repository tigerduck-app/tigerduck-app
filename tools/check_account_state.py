#!/usr/bin/env python3
"""Fail when stored state is added without saying whether a sign-out clears it.

`docs/account-state.md` lists every Keychain key, `Defaults` key and cache file
the app declares, with its scope. Declarations are read where the v4 layout puts
them: `Defaults` keys in any `Defaults.Keys` extension of the app target, cache
files in any source under `Persistence/`. A row of the school or library account
names the function that clears it, and that function's body must mention it; a
Keychain key of an account must also be in the fresh-install wipe in
`AppState.init`. A declaration with no row, or a row with nothing declared, is an
error too, and so is an `AccountScoped` store that no account's list in
`Account/SignOutPlan.swift` names.

Run manually:  python3 tools/check_account_state.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INVENTORY = ROOT / "docs" / "account-state.md"
APP = "swift/TigerDuck"
PERSISTENCE = APP + "/Persistence"
KEYCHAIN_SOURCES = ("swift/TigerDuck/App/AppConstants.swift", "swift/TigerDuck/Backend/Auth/AuthTokenManager.swift")
FRESH_INSTALL_WIPE = ("swift/TigerDuck/App/AppState.swift", "init")
SIGN_OUT_PLAN = APP + "/Account/SignOutPlan.swift"
SCOPES = {"school", "library", "device"}

ROW_RE = re.compile(r"^\|\s*(keychain|defaults|cache)\s*\|\s*`([^`]+)`\s*\|\s*(\w+)\s*\|(.*)\|\s*$")
CLEARER_RE = re.compile(r"`([^`]+\.swift)`\s+`(\w+)`")


def swift_files(root: Path, folder: str) -> list[Path]:
    return sorted((root / folder).rglob("*.swift"))


def declared(root: Path) -> set[tuple[str, str]]:
    found: set[tuple[str, str]] = set()
    constants = (root / KEYCHAIN_SOURCES[0]).read_text()
    block = re.search(r"enum KeychainKeys \{(.*?)\n    \}", constants, re.S)
    for name in re.findall(r"static let (\w+) = \"", block.group(1) if block else ""):
        found.add(("keychain", name))
    tokens = (root / KEYCHAIN_SOURCES[1]).read_text()
    for name in re.findall(r"static let (\w+Key) = \"", tokens):
        found.add(("keychain", name))
    for path in swift_files(root, APP):
        for name in re.findall(r"static let (\w+) = Key<", path.read_text()):
            found.add(("defaults", name))
    for path in swift_files(root, PERSISTENCE):
        found |= cache_files(path.read_text())
    return found


def cache_files(source: str) -> set[tuple[str, str]]:
    found = {("cache", name) for name in re.findall(r"\"([a-z_]+\.json)\"", source)}
    found |= {("cache", name + "*") for name in re.findall(r"hasPrefix\(\"([a-z_]+)\"\)", source)}
    previous = ""
    for line in source.splitlines():
        directory = re.search(r"var (\w+Dir): URL", line)
        literal = re.search(r"appendingPathComponent\(\"(\w+)\", isDirectory: true\)", line)
        if directory:
            found.add(("cache", directory.group(1)))
        elif literal and "var " not in previous and literal.group(1) not in ("TigerDuckCache", "TigerDuckData"):
            found.add(("cache", literal.group(1) + "/"))
        previous = line
    return found


def inventory(text: str) -> dict[tuple[str, str], tuple[str, list[tuple[str, str]]]]:
    rows = {}
    for line in text.splitlines():
        match = ROW_RE.match(line)
        if match:
            store, name, scope, rest = match.groups()
            rows[(store, name)] = (scope, CLEARER_RE.findall(rest))
    return rows


def function_body(source: str, name: str) -> str | None:
    match = re.search(rf"\b(?:(?:func|var) {name}\b[^{{]*|{name}\([^)]*\)\s*|{name}:\s*)\{{", source)
    if not match:
        return None
    depth, start = 0, match.end() - 1
    for index in range(start, len(source)):
        depth += {"{": 1, "}": -1}.get(source[index], 0)
        if depth == 0:
            return source[start:index + 1]
    return None


def unlisted_stores(root: Path) -> list[str]:
    """`AccountScoped` types that no account's sign-out clears."""
    scoped = set()
    for path in swift_files(root, APP):
        scoped |= set(re.findall(r"\b(?:extension|class|struct|enum|actor)\s+(\w+)\s*:[^{]*\bAccountScoped\b",
                                 path.read_text()))
    plan = root / SIGN_OUT_PLAN
    listed = set(re.findall(r"\b(\w+)\.self\b", plan.read_text())) if plan.exists() else set()
    return sorted(scoped - listed)


def mentions(body: str, store: str, name: str) -> bool:
    if store == "cache" and not name.endswith("Dir"):
        return f'"{name.rstrip("*/")}' in body
    return re.search(rf"\b{re.escape(name)}\b", body) is not None


def problems(root: Path = ROOT, text: str | None = None) -> list[str]:
    text = INVENTORY.read_text() if text is None else text
    rows = inventory(text)
    found = declared(root)
    errors = [f"{store} `{name}` has no row in docs/account-state.md" for store, name in sorted(found - rows.keys())]
    errors += [f"{store} `{name}` is listed but no longer declared" for store, name in sorted(rows.keys() - found)]
    errors += [f"`{name}` is AccountScoped but no list in {SIGN_OUT_PLAN} names it" for name in unlisted_stores(root)]
    for (store, name), (scope, clearers) in sorted(rows.items()):
        if scope not in SCOPES:
            errors.append(f"{store} `{name}` has unknown scope {scope}")
            continue
        if scope == "device":
            continue
        if not clearers:
            errors.append(f"{store} `{name}` belongs to an account but names nothing that clears it")
        needed = clearers + ([FRESH_INSTALL_WIPE] if store == "keychain" else [])
        for path, function in needed:
            body = function_body((root / path).read_text(), function) if (root / path).exists() else None
            if body is None:
                errors.append(f"{store} `{name}`: no `{function}` in {path}")
            elif not mentions(body, store, name):
                errors.append(f"{store} `{name}`: `{function}` in {path} does not clear it")
    return errors


def main() -> int:
    errors = problems()
    for error in errors:
        print(error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
