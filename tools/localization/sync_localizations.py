#!/usr/bin/env python3
"""Refresh Apple localization artifacts.

Runs the canonical generator in the localization submodule, then surfaces
each generated `<lang>.lproj` directory into every Apple bundle target as
an individual symlink at `<target-dir>/<lang>.lproj`.

The symlinks live at the root of each target's filesystem-synchronized
group so Xcode discovers each one as a top-level localization bundle and
copies its contents to `<App>.app/<lang>.lproj/`. A single parent
`Localization/` symlink does NOT work: Xcode treats it as a regular
resource folder and copies the `.lproj`s nested inside, producing
`<App>.app/Localization/<lang>.lproj/...` — a path `String(localized:)`
does not search.

Targets handled here:
  - `swift/TigerDuck/`                 — iOS app
  - `swift/TigerDuckWatch Watch App/`  — watchOS companion app
  - `swift/TigerDuckWatchWidget/`      — watchOS complication / widget

Run this whenever `localization/source/*.json` changes (typically right
after a `git submodule update --remote localization`). It's also wired
into each target as a "Run Script" build phase so a normal build keeps
`.lproj` content in sync without manual intervention.

Note: when invoked from Xcode's user-script-sandboxed build phase,
read access to the synchronized-group directory itself may be denied.
We handle that by avoiding `iterdir()` on the target dir during sandboxed
runs and skipping stale-link cleanup. Cleanup runs unsandboxed when the
script is invoked manually.
"""

import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LOCALIZATION_DIR = ROOT / "localization"
GENERATED_APPLE_DIR = LOCALIZATION_DIR / "generated" / "apple"

# Apple bundle targets that need their own per-language `.lproj` symlinks at
# the root of their filesystem-synchronized group. Each entry is two levels
# below ROOT, so the relative symlink target stays `../../localization/...`.
TARGET_DIRS = [
    ROOT / "swift" / "TigerDuck",
    ROOT / "swift" / "TigerDuckWatch Watch App",
    ROOT / "swift" / "TigerDuckWatchWidget",
]

# Widget extension's resources live one level deeper, so it uses a separate
# prefix and its own helpers below.
TIGERDUCK_WIDGETS_DIR = ROOT / "swift" / "TigerDuckWidgets" / "Resources"

LPROJ_TARGET_PREFIX = Path("..") / ".." / "localization" / "generated" / "apple"
WIDGETS_LPROJ_TARGET_PREFIX = Path("..") / ".." / ".." / "localization" / "generated" / "apple"


def is_xcode_build() -> bool:
    return "XCODE_PRODUCT_BUILD_VERSION" in os.environ


def remove_legacy_symlinks() -> None:
    """Drop the historical `<target>/Localization` parent symlink if present."""
    for target_dir in TARGET_DIRS:
        legacy = target_dir / "Localization"
        try:
            if legacy.is_symlink():
                legacy.unlink()
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


def remove_stale_symlinks(target_dir: Path, desired: set[str]) -> None:
    """Drop `<lang>.lproj` symlinks for locales no longer in the source.

    Skipped silently in sandboxed builds where `target_dir` isn't readable.
    """
    try:
        entries = list(target_dir.iterdir())
    except PermissionError:
        return
    for entry in entries:
        if (
            entry.name.endswith(".lproj")
            and entry.is_symlink()
            and entry.name not in desired
        ):
            entry.unlink()


def remove_stale_widgets_symlinks(desired: set[str]) -> None:
    """Drop `<lang>.lproj` symlinks in widgets directory for locales no longer in the source.

    Skipped silently in sandboxed builds where TIGERDUCK_WIDGETS_DIR isn't readable.
    """
    try:
        entries = list(TIGERDUCK_WIDGETS_DIR.iterdir())
    except (PermissionError, FileNotFoundError):
        return
    for entry in entries:
        if (
            entry.name.endswith(".lproj")
            and entry.is_symlink()
            and entry.name not in desired
        ):
            entry.unlink()


def ensure_symlink(target_dir: Path, name: str) -> None:
    link_path = target_dir / name
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


def ensure_widgets_symlink(name: str) -> None:
    link_path = TIGERDUCK_WIDGETS_DIR / name
    target = WIDGETS_LPROJ_TARGET_PREFIX / name
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
    desired_set = set(desired)
    for target_dir in TARGET_DIRS:
        if not target_dir.is_dir():
            # Target not present in this checkout (e.g. running on a branch
            # where the watch app folder hasn't been created yet); skip.
            continue
        if not is_xcode_build():
            remove_stale_symlinks(target_dir, desired_set)
        for name in desired:
            ensure_symlink(target_dir, name)

    # Widgets resources directory is one level deeper than the other targets,
    # so it uses a separate set of helpers with a different relative prefix.
    TIGERDUCK_WIDGETS_DIR.mkdir(parents=True, exist_ok=True)
    if not is_xcode_build():
        remove_stale_widgets_symlinks(desired_set)
    for name in desired:
        ensure_widgets_symlink(name)


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
        remove_legacy_symlinks()
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
