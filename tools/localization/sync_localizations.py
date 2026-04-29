#!/usr/bin/env python3
"""Refresh Apple localization artifacts.

Runs the canonical generator in the localization submodule. The generated
`localization/generated/apple/*.lproj/` directories are surfaced into the
Xcode target via the symlink at `swift/TigerDuck/Localization`, which is
auto-discovered by the filesystem-synchronized root group.

Run this whenever `localization/source/*.json` changes (typically right
after a `git submodule update --remote localization`). It's also wired
into the TigerDuck target as a "Run Script" build phase so a normal
build keeps `.lproj` content in sync without manual intervention.
"""

import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LOCALIZATION_DIR = ROOT / "localization"
SYMLINK_PATH = ROOT / "swift" / "TigerDuck" / "Localization"
SYMLINK_TARGET = Path("../../localization/generated/apple")


def ensure_symlink() -> None:
    if SYMLINK_PATH.is_symlink():
        return
    if SYMLINK_PATH.exists():
        raise SystemExit(
            f"{SYMLINK_PATH} exists but is not a symlink; refusing to overwrite. "
            "Move it aside and re-run."
        )
    SYMLINK_PATH.symlink_to(SYMLINK_TARGET)


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
        ensure_symlink()
        run_canonical_generator()
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
