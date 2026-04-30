#!/usr/bin/env python3
"""Refresh Apple localization artifacts.

Runs the canonical generator in the localization submodule, then surfaces
each generated `<lang>.lproj` directory into the TigerDuck target as an
individual symlink at `swift/TigerDuck/<lang>.lproj`.

The symlinks live at the root of the `swift/TigerDuck/` filesystem-
synchronized group so Xcode discovers each one as a top-level
localization bundle and copies its contents to `<App>.app/<lang>.lproj/`.
A single parent `Localization/` symlink does NOT work: Xcode treats it
as a regular resource folder and copies the `.lproj`s nested inside,
producing `<App>.app/Localization/<lang>.lproj/...` — a path
`String(localized:)` does not search.

Run this whenever `localization/source/*.json` changes (typically right
after a `git submodule update --remote localization`). It's also wired
into the TigerDuck target as a "Run Script" build phase so a normal
build keeps `.lproj` content in sync without manual intervention.

Note: when invoked from Xcode's user-script-sandboxed build phase,
read access to the synchronized-group directory itself (`swift/TigerDuck`)
may be denied. We handle that by avoiding `iterdir()` on that path during
sandboxed runs and skipping stale-link cleanup. Cleanup runs unsandboxed
when the script is invoked manually.
"""

import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LOCALIZATION_DIR = ROOT / "localization"
GENERATED_APPLE_DIR = LOCALIZATION_DIR / "generated" / "apple"
TIGERDUCK_DIR = ROOT / "swift" / "TigerDuck"

LEGACY_PARENT_SYMLINK = TIGERDUCK_DIR / "Localization"
LPROJ_TARGET_PREFIX = Path("..") / ".." / "localization" / "generated" / "apple"


def is_xcode_build() -> bool:
    return "XCODE_PRODUCT_BUILD_VERSION" in os.environ


def remove_legacy_symlink() -> None:
    try:
        if LEGACY_PARENT_SYMLINK.is_symlink():
            LEGACY_PARENT_SYMLINK.unlink()
    except PermissionError:
        # Sandboxed run — cleanup not required since the legacy symlink
        # has already been removed in any healthy checkout.
        pass


def desired_lproj_names() -> list[str]:
    if not GENERATED_APPLE_DIR.exists():
        raise SystemExit(
            f"Generated localizations not found at {GENERATED_APPLE_DIR}. "
            "The canonical generator should have produced them."
        )
    return sorted(
        entry.name
        for entry in GENERATED_APPLE_DIR.iterdir()
        if entry.is_dir() and entry.name.endswith(".lproj")
    )


def remove_stale_symlinks(desired: set[str]) -> None:
    """Drop `<lang>.lproj` symlinks for locales no longer in the source.

    Skipped silently in sandboxed builds where TIGERDUCK_DIR isn't readable.
    """
    try:
        entries = list(TIGERDUCK_DIR.iterdir())
    except PermissionError:
        return
    for entry in entries:
        if (
            entry.name.endswith(".lproj")
            and entry.is_symlink()
            and entry.name not in desired
        ):
            entry.unlink()


def ensure_symlink(name: str) -> None:
    link_path = TIGERDUCK_DIR / name
    target = LPROJ_TARGET_PREFIX / name
    if link_path.is_symlink():
        if Path(os.readlink(link_path)) == target:
            return
        link_path.unlink()
    elif link_path.exists():
        raise SystemExit(
            f"{link_path} exists but is not a symlink; refusing to overwrite. "
            "Move it aside and re-run."
        )
    link_path.symlink_to(target)


def sync_lproj_symlinks() -> None:
    desired = desired_lproj_names()
    if not is_xcode_build():
        remove_stale_symlinks(set(desired))
    for name in desired:
        ensure_symlink(name)


def run_canonical_generator() -> None:
    script = LOCALIZATION_DIR / "tools" / "localization" / "generate_localizations.py"
    if not script.exists():
        raise SystemExit(
            f"Canonical generator not found at {script}. "
            "Run `git submodule update --init --recursive` first."
        )
    subprocess.check_call([sys.executable, str(script)])


def main() -> int:
    try:
        remove_legacy_symlink()
        run_canonical_generator()
        sync_lproj_symlinks()
    except subprocess.CalledProcessError as error:
        print(f"Canonical generator failed: {error}", file=sys.stderr)
        return error.returncode or 1
    except Exception as error:
        print(f"Localization sync failed: {error}", file=sys.stderr)
        return 1

    print("Localization sync complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
