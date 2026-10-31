"""Tests for tools/check_architecture.py: python3 -m unittest discover -s tools -p 'test_*.py'"""
import unittest

import check_architecture as ca

APP = "swift/TigerDuck/"


def source(path: str, text: str) -> ca.Source:
    return ca.Source(path, text, ca.strip_code(text))


def rules(found: list[ca.Finding]) -> list[str]:
    return [f.rule for f in found]


def body(lines: int) -> str:
    return "".join(f"    let value{i} = {i}\n" for i in range(lines))


class ArchitectureTests(unittest.TestCase):
    def test_the_repository_passes_the_enforced_phase(self) -> None:
        self.assertEqual(ca.enforced(ca.findings()), [])

    def test_only_rules_up_to_the_enforced_phase_fail(self) -> None:
        early = ca.Finding("a.swift", 1, "taipei-zone", "")
        late = ca.Finding("a.swift", 1, "task-sleep", "")
        self.assertEqual(ca.enforced([early, late]), [early])

    def test_the_taipei_zone_outside_core_fails_with_its_line(self) -> None:
        text = 'import Foundation\nlet zone = TimeZone(identifier: "Asia/Taipei")\n'
        found = ca.pattern_findings([source(APP + "School/X.swift", text),
                                     source(ca.CORE_SOURCES + "TigerDuckCore/X.swift", text)])
        self.assertEqual([(f.path, f.line, f.rule) for f in found], [(APP + "School/X.swift", 2, "taipei-zone")])
        self.assertIn("TaipeiTime", found[0].message)

    def test_the_taipei_rule_covers_the_other_targets(self) -> None:
        listed = ca.other_target_paths(ca.ROOT, [])
        self.assertTrue(any(p.startswith("swift/TigerDuckWidgets/") for p in listed))
        self.assertTrue(any(p.startswith("swift/TigerDuckWatch Watch App/") for p in listed))
        text = 'let zone = TimeZone(identifier: "Asia/Taipei")\n'
        found = ca.taipei_findings([source("swift/TigerDuckWidgets/X.swift", text)])
        self.assertEqual([(f.path, f.rule) for f in found], [("swift/TigerDuckWidgets/X.swift", "taipei-zone")])

    def test_the_roc_year_offset_outside_core_fails_in_every_target(self) -> None:
        text = "// 1911 years before ROC 1\nlet year = parts.year - 1911\nlet port = 19110\n"
        found = ca.core_findings([source(APP + "Features/X.swift", text),
                                  source("swift/TigerDuckWidgets/X.swift", text),
                                  source(ca.CORE_SOURCES + "TigerDuckCore/AcademicTerm.swift", text)])
        self.assertEqual([(f.path, f.line, f.rule) for f in found],
                         [(APP + "Features/X.swift", 2, "academic-term"), ("swift/TigerDuckWidgets/X.swift", 2, "academic-term")])
        self.assertIn("AcademicTerm", found[0].message)

    def test_a_pattern_in_a_comment_or_a_string_is_not_code(self) -> None:
        text = '// Task.sleep would poll here\nlet s = "Task.sleep(for:)"\n/* UserDefaults.standard */\n'
        self.assertEqual(ca.pattern_findings([source(APP + "Features/X.swift", text)]), [])

    def test_a_pattern_in_its_home_folder_passes(self) -> None:
        text = "try await Task.sleep(for: .seconds(1))\n"
        found = ca.pattern_findings([source(APP + "Support/Clock/AppClock.swift", text),
                                     source(APP + "Features/Home/X.swift", text)])
        self.assertEqual([(f.path, f.rule) for f in found], [(APP + "Features/Home/X.swift", "task-sleep")])

    def test_each_pattern_rule_reports_its_rule(self) -> None:
        text = ("if gen == loginGeneration {}\nlet d = UserDefaults(suiteName: group)\n"
                "let s = URLSession(configuration: .default)\nNotificationCenter.default.post(name: dataDidUpdate)\n"
                "isUpdatingFromNetwork = true\n")
        found = ca.pattern_findings([source(APP + "Features/X.swift", text)])
        self.assertEqual(rules(found), ["login-generation", "data-did-update", "is-updating-from-network",
                                        "user-defaults", "url-session"])

    def test_two_app_files_with_one_base_name_fail(self) -> None:
        found = ca.base_name_findings([APP + "App/Foo.swift", APP + "School/Foo.swift", APP + "Bar.swift"])
        self.assertEqual([f.path for f in found], [APP + "App/Foo.swift", APP + "School/Foo.swift"])

    def test_an_on_screen_entry_must_name_a_test_that_exists(self) -> None:
        workflow = ("          - leg: phone\n            on_screen_tests: >-\n"
                    "              TigerDuckTests/PageTests\n"
                    "              TigerDuckTests/PageTests/opens(width:)\n"
                    "              TigerDuckTests/PageTests/closes()\n"
                    "              TigerDuckTests/GoneTests\n"
                    "          - leg: watch\n")
        code = "@MainActor struct PageTests {\n    @Test func opens(width: Int) {}\n}\n"
        found = ca.on_screen_findings(workflow, code)
        self.assertEqual([(f.line, f.message.split("`")[1]) for f in found], [(5, "closes"), (6, "GoneTests")])

    def test_a_type_counts_its_extensions_and_not_its_nested_types(self) -> None:
        main = "struct Store {\n" + body(200) + "    struct Row {\n" + body(100) + "    }\n}\n"
        ext = "extension Store {\n" + body(60) + "}\n"
        found = ca.size_findings([source(APP + "A.swift", main), source(APP + "B.swift", ext)])
        self.assertEqual([(f.rule, f.path, f.line) for f in found], [("type-size", APP + "A.swift", 1)])
        self.assertIn("`Store` is 264 lines", found[0].message)

    def test_a_view_has_the_smaller_budget(self) -> None:
        view = "struct Page: View {\n" + body(210) + "}\n"
        model = "struct Model {\n" + body(210) + "}\n"
        found = ca.size_findings([source(APP + "Page.swift", view), source(APP + "Model.swift", model)])
        self.assertEqual([f.message.split("`")[1] for f in found], ["Page"])

    def test_a_class_with_more_than_ten_stored_properties_fails(self) -> None:
        stored = "".join(f"    var value{i} = {i}\n" for i in range(11))
        others = "    static let shared = 1\n    var computed: Int { 1 }\n    lazy var later = 1\n"
        model = "@Observable final class Model {\n" + stored + others + "}\n"
        found = ca.size_findings([source(APP + "A.swift", model),
                                  source(APP + "B.swift", "struct Plain {\n" + stored + "}\n")])
        self.assertEqual(rules(found), ["stored-properties"])
        self.assertIn("holds 12 stored properties", found[0].message)

    def test_a_file_over_its_budget_fails(self) -> None:
        found = ca.size_findings([source(APP + "A.swift", "\n" * 401)])
        self.assertEqual(rules(found), ["file-size"])

    def test_a_feature_using_a_school_type_fails_once_per_type(self) -> None:
        school = source(APP + "School/NTUST/Parser.swift", "enum ScoreParser {\n    enum Row {}\n}\n")
        feature = source(APP + "Features/Score/View.swift", "let a = ScoreParser.parse()\nlet b = ScoreParser.Row()\n")
        found = ca.layering_findings([school, feature])
        self.assertEqual([(f.path, f.line, f.rule) for f in found],
                         [(APP + "Features/Score/View.swift", 1, "feature-layering")])


if __name__ == "__main__":
    unittest.main()
