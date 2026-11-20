"""Tests for tools/generate_app_icon_previews.py: python3 -m unittest discover -s tools -p 'test_*.py'"""
import json
import shutil
import tempfile
import unittest
from pathlib import Path

import generate_app_icon_previews as previews


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.icons = self.root / "AppIcons"
        self.digests = self.root / "digests.json"
        self.document("Duck")
        self.render("Duck")

    def document(self, name):
        assets = self.icons / f"{name}.icon" / "Assets"
        assets.mkdir(parents=True)
        (assets / "00_duck.png").write_bytes(b"duck")
        (self.icons / f"{name}.icon" / "icon.json").write_text('{"groups": []}')

    def render(self, name):
        folder = previews.imageset(self.icons, name)
        folder.mkdir(parents=True)
        for suffix in previews.RENDITIONS:
            (folder / f"{name}{suffix}.png").write_bytes(b"png")
        (folder / "Contents.json").write_text(previews.imageset_contents(name))
        recorded = previews.read_digests(self.digests)
        recorded[name] = previews.digest(self.icons / f"{name}.icon")
        self.digests.write_text(json.dumps(recorded))

    def problems(self):
        return previews.problems(self.icons, self.digests)

    def test_current_previews_pass(self):
        self.assertEqual(self.problems(), [])

    def test_a_changed_layer_makes_the_previews_stale(self):
        (self.icons / "Duck.icon" / "Assets" / "00_duck.png").write_bytes(b"santa duck")
        self.assertEqual(self.problems(), ["Duck: previews older than Duck.icon"])

    def test_a_renamed_layer_makes_the_previews_stale(self):
        assets = self.icons / "Duck.icon" / "Assets"
        (assets / "00_duck.png").rename(assets / "00_tiger_duck.png")
        self.assertEqual(self.problems(), ["Duck: previews older than Duck.icon"])

    def test_finder_metadata_is_not_a_change(self):
        (self.icons / "Duck.icon" / ".DS_Store").write_bytes(b"finder")
        self.assertEqual(self.problems(), [])

    def test_a_new_document_needs_previews(self):
        self.document("Tiger")
        self.assertEqual(self.problems(), ["Tiger: no previews"])

    def test_a_missing_dark_preview_fails(self):
        (previews.imageset(self.icons, "Duck") / "Duck-dark.png").unlink()
        self.assertEqual(self.problems(), ["Duck: no previews"])

    def test_previews_of_a_deleted_document_fail(self):
        shutil.rmtree(self.icons / "Duck.icon")
        self.assertEqual(self.problems(), ["Duck: previews or a digest of a document swift/AppIcons/ no longer has"])

    def test_the_committed_previews_are_current(self):
        self.assertEqual(previews.problems(), [])


if __name__ == "__main__":
    unittest.main()
