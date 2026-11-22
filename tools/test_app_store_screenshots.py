"""Tests for tools/app_store_screenshots.py: python3 -m unittest discover -s tools -p 'test_*.py'"""
import json
import shutil
import tempfile
import unittest
from datetime import date, datetime
from pathlib import Path

import app_store_screenshots as shots
from make_archive_fixtures import png

IPHONE = shots.DEVICES[0]
DUO = shots.DEVICES[1]


class SizeTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.folder)

    def shot(self, name, data):
        (self.folder / name).write_bytes(data)

    def test_accepted_sizes_pass(self):
        self.shot("01-home.png", png(1206, 2622))
        self.assertEqual(shots.size_problems(self.folder, IPHONE), [])

    def test_either_duo_display_passes(self):
        self.shot("01-home.png", png(1398, 2034))
        self.shot("02-class-table.png", png(2007, 2853))
        self.assertEqual(shots.size_problems(self.folder, DUO), [])

    def test_another_size_fails(self):
        self.shot("01-home.png", png(1206, 2622))
        self.shot("02-class-table.png", png(1179, 2556))
        problems = shots.size_problems(self.folder, IPHONE)
        self.assertEqual(len(problems), 1)
        self.assertIn("02-class-table.png: 1179x2556", problems[0])

    def test_landscape_fails(self):
        self.shot("01-home.png", png(2622, 1206))
        self.assertEqual(len(shots.size_problems(self.folder, IPHONE)), 1)

    def test_a_file_that_is_not_a_png_fails(self):
        self.shot("01-home.png", b"\xff\xd8\xff\xe0 a JPEG")
        self.shot("02-class-table.png", b"")
        problems = shots.size_problems(self.folder, IPHONE)
        self.assertEqual(len(problems), 2)
        self.assertIn("not a PNG", problems[0])

    def test_an_empty_folder_fails(self):
        self.assertEqual(len(shots.size_problems(self.folder, IPHONE)), 1)


class ClockTests(unittest.TestCase):
    def test_every_day_of_a_week_pins_its_tuesday(self):
        for day in range(23, 30):
            self.assertEqual(shots.pinned_clock(date(2026, 11, day)),
                             datetime(2026, 11, 24, 9, 41, tzinfo=shots.TAIPEI))

    def test_the_argument_is_the_override_as_property_list_data(self):
        argument = shots.clock_argument(datetime(2026, 11, 24, 9, 41, tzinfo=shots.TAIPEI))
        self.assertTrue(argument.startswith("<") and argument.endswith(">"))
        override = json.loads(bytes.fromhex(argument[1:-1]))
        self.assertEqual(override, {"instant": 817177260.0, "frozen": True, "savedAtReal": 817177260.0})


if __name__ == "__main__":
    unittest.main()
