#!/usr/bin/env python3
"""Render the app icon picker's previews from the Icon Composer documents in swift/AppIcons/.

iOS gives an app no image of its own alternate icons, so the picker in Settings shows previews
rendered ahead of time with Xcode's ictool: a light and a dark PNG per document, in
swift/AppIcons/Previews.xcassets/<name>Preview.imageset/. tools/app-icon-previews.json keeps a
digest of each document as it was rendered.

After adding, changing or deleting a document in swift/AppIcons/ (needs Xcode 26 or later, from
`xcode-select -p` or DEVELOPER_DIR):

    python3 tools/generate_app_icon_previews.py

Check that every document has current previews, offline and without Xcode (what CI runs):

    python3 tools/generate_app_icon_previews.py --check
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICONS = ROOT / "swift" / "AppIcons"
DIGESTS = ROOT / "tools" / "app-icon-previews.json"
# The picker draws each icon 76 points wide; 3x covers every iPhone.
RENDER = ["--platform", "iOS", "--width", "76", "--height", "76", "--scale", "3"]
RENDITIONS = {"": "Default", "-dark": "Dark"}
XCODE_INFO = {"author": "xcode", "version": 1}


def catalog(icons: Path) -> Path:
    return icons / "Previews.xcassets"


def imageset(icons: Path, name: str) -> Path:
    return catalog(icons) / f"{name}Preview.imageset"


def documents(icons: Path) -> dict[str, Path]:
    found: dict[str, Path] = {}
    for path in sorted(icons.rglob("*.icon")):
        if path.stem in found:
            sys.exit(f"error: {found[path.stem]} and {path} share the asset name {path.stem}")
        found[path.stem] = path
    return found


def digest(document: Path) -> str:
    sha = hashlib.sha256(" ".join(RENDER).encode())
    for file in sorted(p for p in document.rglob("*") if p.is_file() and p.name != ".DS_Store"):
        sha.update(file.relative_to(document).as_posix().encode() + b"\0")
        sha.update(file.read_bytes())
    return sha.hexdigest()


def xcode_json(value: object) -> str:
    """JSON as Xcode writes an asset catalog's Contents.json, so opening it in Xcode changes nothing."""
    return json.dumps(value, indent=2, separators=(",", " : "), sort_keys=True) + "\n"


def imageset_contents(name: str) -> str:
    images = []
    for suffix in RENDITIONS:
        image = {"filename": f"{name}{suffix}.png", "idiom": "universal"}
        if suffix:
            image["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
        images.append(image)
    return xcode_json({"images": images, "info": XCODE_INFO})


def read_digests(path: Path) -> dict[str, str]:
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}


def problems(icons: Path = ICONS, digests: Path = DIGESTS) -> list[str]:
    docs = documents(icons)
    recorded = read_digests(digests)
    rendered = {p.name.removesuffix("Preview.imageset") for p in catalog(icons).glob("*Preview.imageset")}
    found = []
    for name in sorted(docs.keys() | recorded.keys() | rendered):
        if name not in docs:
            found.append(f"{name}: previews or a digest of a document swift/AppIcons/ no longer has")
            continue
        folder = imageset(icons, name)
        contents = folder / "Contents.json"
        pngs = [folder / f"{name}{suffix}.png" for suffix in RENDITIONS]
        if not all(p.is_file() for p in [contents, *pngs]):
            found.append(f"{name}: no previews")
        elif contents.read_text(encoding="utf-8") != imageset_contents(name) or recorded.get(name) != digest(docs[name]):
            found.append(f"{name}: previews older than {name}.icon")
    return found


def ictool() -> str:
    """Icon Composer's ictool; the one `xcrun` finds is the asset catalog compiler's, which cannot render."""
    developer = os.environ.get("DEVELOPER_DIR") or subprocess.run(
        ["xcode-select", "-p"], capture_output=True, text=True, check=True
    ).stdout.strip()
    tool = Path(developer).parent / "Applications" / "Icon Composer.app" / "Contents" / "Executables" / "ictool"
    if not tool.is_file():
        sys.exit(f"error: no ictool at {tool}; set DEVELOPER_DIR to Xcode 26 or later's Contents/Developer")
    return str(tool)


def generate(icons: Path = ICONS, digests: Path = DIGESTS) -> None:
    tool = ictool()
    docs = documents(icons)
    root = catalog(icons)
    root.mkdir(exist_ok=True)
    (root / "Contents.json").write_text(xcode_json({"info": XCODE_INFO}), encoding="utf-8")
    for stale in root.glob("*Preview.imageset"):
        if stale.name.removesuffix("Preview.imageset") not in docs:
            shutil.rmtree(stale)
    for name, document in docs.items():
        folder = imageset(icons, name)
        folder.mkdir(exist_ok=True)
        for suffix, rendition in RENDITIONS.items():
            output = folder / f"{name}{suffix}.png"
            subprocess.run(
                [tool, str(document), "--export-image", "--output-file", str(output), "--rendition", rendition, *RENDER],
                check=True,
                stdout=subprocess.DEVNULL,
            )
        (folder / "Contents.json").write_text(imageset_contents(name), encoding="utf-8")
        print(f"rendered {name}")
    digests.write_text(xcode_json({name: digest(doc) for name, doc in docs.items()}), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="verify the committed previews, without Xcode")
    if not parser.parse_args().check:
        generate()
    found = problems()
    for problem in found:
        print(f"error: {problem}; run `python3 tools/generate_app_icon_previews.py`", file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
