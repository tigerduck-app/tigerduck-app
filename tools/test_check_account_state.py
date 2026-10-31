"""Tests for tools/check_account_state.py: python3 -m unittest discover -s tools -p 'test_*.py'"""
import shutil
import tempfile
import unittest
from pathlib import Path

import check_account_state as cas

SOURCES = sorted({path for _, (_, clearers) in cas.inventory(cas.INVENTORY.read_text()).items() for path, _ in clearers}
                 | {cas.FRESH_INSTALL_WIPE[0], *cas.KEYCHAIN_SOURCES, "swift/TigerDuck/App/AppDefaults.swift",
                    *(p.relative_to(cas.ROOT).as_posix() for p in cas.swift_files(cas.ROOT, cas.PERSISTENCE))})


class AccountStateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        for path in SOURCES:
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(cas.ROOT / path, self.root / path)

    def write(self, path: str, text: str) -> None:
        (self.root / path).parent.mkdir(parents=True, exist_ok=True)
        (self.root / path).write_text(text)

    def edit(self, path: str, old: str, new: str) -> None:
        source = (self.root / path).read_text()
        self.assertIn(old, source)
        (self.root / path).write_text(source.replace(old, new, 1))

    def test_the_repository_lists_and_clears_every_store(self) -> None:
        self.assertEqual(cas.problems(), [])

    def test_a_new_defaults_key_without_a_row_fails(self) -> None:
        self.edit("swift/TigerDuck/App/AppDefaults.swift", "    static let schoolDataSyncedAt",
                  '    static let lastViewedCourse = Key<String?>("lastViewedCourse")\n    static let schoolDataSyncedAt')
        self.assertIn("defaults `lastViewedCourse` has no row in docs/account-state.md", cas.problems(self.root))

    def test_a_new_cache_file_without_a_row_fails(self) -> None:
        self.edit("swift/TigerDuck/Persistence/DataCache.swift", '"assignments.json"', '"exam_seats.json"')
        self.assertIn("cache `exam_seats.json` has no row in docs/account-state.md", cas.problems(self.root))

    def test_a_cache_file_of_another_persistence_store_without_a_row_fails(self) -> None:
        self.write("swift/TigerDuck/Persistence/Courses/ExamSeatStore.swift",
                   'struct ExamSeatStore {\n    let name = "exam_seats.json"\n}\n')
        self.assertIn("cache `exam_seats.json` has no row in docs/account-state.md", cas.problems(self.root))

    def test_a_defaults_key_declared_outside_app_defaults_without_a_row_fails(self) -> None:
        self.write("swift/TigerDuck/Features/Exams/ExamDefaults.swift",
                   'extension Defaults.Keys {\n    static let examSeatShown = Key<Bool>("examSeatShown", default: false)\n}\n')
        self.assertIn("defaults `examSeatShown` has no row in docs/account-state.md", cas.problems(self.root))

    def test_a_new_keychain_item_without_a_row_fails(self) -> None:
        self.edit("swift/TigerDuck/Backend/Auth/AuthTokenManager.swift", "    static let departingSessionKey",
                  '    static let deviceSecretKey = "v3_device_secret"\n    static let departingSessionKey')
        self.assertIn("keychain `deviceSecretKey` has no row in docs/account-state.md", cas.problems(self.root))

    def test_an_account_key_the_sign_out_stops_clearing_fails(self) -> None:
        self.edit("swift/TigerDuck/Account/SchoolAccountKeys.swift", "Defaults[.schoolDataSyncedAt] = nil\n", "")
        self.assertIn("defaults `schoolDataSyncedAt`: `forgetAccount` in swift/TigerDuck/Account/SchoolAccountKeys.swift"
                      " does not clear it", cas.problems(self.root))

    def test_an_account_scoped_store_no_sign_out_lists_fails(self) -> None:
        self.write("swift/TigerDuck/Features/Exams/ExamSeatStore.swift",
                   "final class ExamSeatStore: AccountScoped {\n"
                   "    static func forgetAccount(in storage: AccountStorage) {}\n}\n")
        self.assertIn("`ExamSeatStore` is AccountScoped but no list in swift/TigerDuck/Account/SignOutPlan.swift names it",
                      cas.problems(self.root))
        self.edit("swift/TigerDuck/Account/SignOutPlan.swift", "LibraryService.self]", "LibraryService.self, ExamSeatStore.self]")
        self.assertEqual(cas.problems(self.root), [])

    def test_a_cache_file_the_sign_out_stops_clearing_fails(self) -> None:
        self.edit("swift/TigerDuck/Persistence/DataCache.swift", '("ignored_courses.json", persistentDir),\n', "")
        self.assertIn("cache `ignored_courses.json`: `clearUserScopedData` in swift/TigerDuck/Persistence/DataCache.swift"
                      " does not clear it", cas.problems(self.root))

    def test_an_account_keychain_key_the_fresh_install_keeps_fails(self) -> None:
        self.edit("swift/TigerDuck/App/AppState.swift", "AuthTokenManager.refreshTokenUsesKey,\n", "")
        self.assertIn("keychain `refreshTokenUsesKey`: `init` in swift/TigerDuck/App/AppState.swift does not clear it",
                      cas.problems(self.root))

    def test_an_account_row_that_names_no_clearer_fails(self) -> None:
        text = cas.INVENTORY.read_text().replace(
            "| defaults | `schoolDataSyncedAt` | school | `swift/TigerDuck/Account/SchoolAccountKeys.swift` `forgetAccount` |",
            "| defaults | `schoolDataSyncedAt` | school | |")
        self.assertIn("defaults `schoolDataSyncedAt` belongs to an account but names nothing that clears it",
                      cas.problems(self.root, text))


if __name__ == "__main__":
    unittest.main()
