"""Tests for tools/check_macos_sources.py: python3 -m unittest discover -s tools -p 'test_*.py'"""
import unittest

import check_macos_sources as cms

# The two build configurations of the app target, as project.pbxproj writes them.
PROJECT = """\t\tAAAA /* Debug */ = {
\t\t\tbuildSettings = {
\t\t\t\t"INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]" = (
%s
\t\t\t\t);
\t\t\t};
\t\t};
\t\tBBBB /* Release */ = {
\t\t\tbuildSettings = {
\t\t\t\t"INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]" = (
%s
\t\t\t\t);
\t\t\t};
\t\t};
"""
SOURCES = ["swift/Shared/TLSPins/TLSPinTable.swift", "swift/TigerDuck/App/AppState+Account.swift",
           "swift/TigerDuck/App/AppState.swift", "swift/TigerDuck/Mail/Core/MailClient.swift"]
EXCLUDED = {"MailClient.swift"}


def project(*entries: str, release: tuple[str, ...] | None = None) -> str:
    def block(names: tuple[str, ...]) -> str:
        return "\n".join(f"\t\t\t\t\t{n}," for n in names)
    return PROJECT % (block(entries), block(entries if release is None else release))


class MacOSSourcesTests(unittest.TestCase):
    def test_the_repository_arrays_are_generated(self) -> None:
        text = cms.PBXPROJ.read_text(encoding="utf-8")
        self.assertEqual(cms.problems(text, cms.tracked_target_sources(text), cms.read_excluded()), [])

    def test_write_lists_every_source_but_the_excluded_sorted_and_quoted(self) -> None:
        text = cms.rewrite(project("Stale.swift"), cms.expected_allowlist(SOURCES, EXCLUDED))
        self.assertEqual(cms.parse_allowlists(text), [["AppState+Account.swift", "AppState.swift", "TLSPinTable.swift"]] * 2)
        self.assertIn('\t\t\t\t\t"AppState+Account.swift",\n\t\t\t\t\tAppState.swift,\n', text)
        self.assertEqual(cms.problems(text, SOURCES, EXCLUDED), [])

    def test_a_new_file_missing_from_the_arrays_fails(self) -> None:
        text = project('"AppState+Account.swift"', "AppState.swift")
        found = cms.problems(text, SOURCES, EXCLUDED)
        self.assertEqual(len(found), 2)
        self.assertIn("missing: TLSPinTable.swift", found[0])

    def test_one_configuration_drifting_fails(self) -> None:
        names = ('"AppState+Account.swift"', "AppState.swift", "TLSPinTable.swift")
        found = cms.problems(project(*names, release=names[:2]), SOURCES, EXCLUDED)
        self.assertEqual(len(found), 1)
        self.assertIn("array #2", found[0])

    def test_unsorted_arrays_fail(self) -> None:
        found = cms.problems(project("AppState.swift", '"AppState+Account.swift"', "TLSPinTable.swift"), SOURCES, EXCLUDED)
        self.assertIn("entries are not sorted", found[0])

    def test_two_files_with_one_base_name_fail(self) -> None:
        sources = SOURCES + ["swift/TigerDuck/School/AppState.swift"]
        text = cms.rewrite(project(), cms.expected_allowlist(sources, EXCLUDED))
        found = cms.problems(text, sources, EXCLUDED)
        self.assertEqual(len(found), 1)
        self.assertIn("AppState.swift: swift/TigerDuck/App/AppState.swift, swift/TigerDuck/School/AppState.swift", found[0])

    def test_an_excluded_name_without_a_file_fails(self) -> None:
        excluded = EXCLUDED | {"Gone.swift"}
        text = cms.rewrite(project(), cms.expected_allowlist(SOURCES, excluded))
        self.assertIn("    Gone.swift\n", cms.problems(text, SOURCES, excluded)[0])


if __name__ == "__main__":
    unittest.main()
