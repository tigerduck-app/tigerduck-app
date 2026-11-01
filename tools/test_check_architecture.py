"""Tests for tools/check_architecture.py: python3 -m unittest discover -s tools -p 'test_*.py'"""
import unittest
from unittest import mock

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
        with mock.patch.object(ca, "ENFORCED_PHASE", 6):
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
                "isUpdatingFromNetwork = true\nlet c = BackendClient(auth: .unbound { token })\n")
        found = ca.pattern_findings([source(APP + "Features/X.swift", text)])
        self.assertEqual(rules(found), ["login-generation", "data-did-update", "is-updating-from-network",
                                        "user-defaults", "url-session", "unbound-backend-auth"])

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

    def test_a_suite_that_shows_a_window_must_be_in_the_on_screen_list(self) -> None:
        workflow = ("          - leg: phone\n            on_screen_tests: >-\n"
                    "              TigerDuckTests/ListedTests\n"
                    "              TigerDuckTests/FuncTests/shows()\n")
        window = "struct %s {\n    func shows() {\n        window.makeKeyAndVisible()\n    }\n}\n"
        tests = {"A.swift": window % "ListedTests", "B.swift": window % "FuncTests",
                 "C.swift": window % "MissingTests",
                 "D.swift": "struct WebTests {\n    let view = WKWebView(frame: .zero)\n}\n",
                 "E.swift": "struct PlainTests {\n    let view: WKWebView? = nil\n    // field.becomeFirstResponder()\n}\n"}
        found = ca.unlisted_on_screen_findings(workflow, {k: ca.strip_code(v) for k, v in tests.items()})
        self.assertEqual([(f.path, f.message.split("`")[1]) for f in found],
                         [("C.swift", "MissingTests"), ("D.swift", "WebTests")])

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

    def test_a_swiftdata_model_keeps_its_stored_properties(self) -> None:
        stored = "".join(f"    var value{i} = {i}\n" for i in range(11))
        model = "@Model\nfinal class Row {\n    @Attribute(.unique) var id = 0\n" + stored + "}\n"
        plain = "final class Plain {\n    @Attribute(.unique) var id = 0\n" + stored + "}\n"
        found = ca.size_findings([source(APP + "A.swift", model), source(APP + "B.swift", plain)])
        self.assertEqual([(f.rule, f.path) for f in found], [("stored-properties", APP + "B.swift")])

    def test_a_file_over_its_budget_fails(self) -> None:
        found = ca.size_findings([source(APP + "A.swift", "\n" * 401)])
        self.assertEqual(rules(found), ["file-size"])

    def test_a_feature_using_a_school_type_fails_once_per_type(self) -> None:
        school = source(APP + "School/NTUST/Parser.swift", "enum ScoreParser {\n    enum Row {}\n}\n")
        feature = source(APP + "Features/Score/View.swift", "let a = ScoreParser.parse()\nlet b = ScoreParser.Row()\n")
        found = ca.layering_findings([school, feature])
        self.assertEqual([(f.path, f.line, f.rule) for f in found],
                         [(APP + "Features/Score/View.swift", 1, "feature-layering")])

    def test_a_sign_in_read_outside_where_account_work_starts_fails(self) -> None:
        text = "let signIn = AccountSession.school.currentSignIn\nawait session.withSignIn { _ in }\n"
        found = ca.sign_in_findings([source(APP + "Features/Home/X.swift", text),
                                     source(APP + "Stores/X.swift", text)])
        self.assertEqual([(f.path, f.line, f.rule) for f in found],
                         [(APP + "Stores/X.swift", 1, "sign-in-read"), (APP + "Stores/X.swift", 2, "sign-in-read")])

    def test_a_sign_in_compared_by_hand_fails_outside_the_account_layer(self) -> None:
        text = ("if signIn == other.signIn {}\nlet s = SignInSeries()\nsignIns.end()\n"
                "if signIn.isCurrent {}\nif phase.signIn == .idle {}\nif signIn != nil {}\nlet a = x == y.signIn.phase\n"
                "if [first, signIn].contains(x) {}\nif seen.contains(task.signIn) {}\nvar ended: Set<SignIn> = []\n"
                "var byRun: [SignIn: Int] = [:]\nif self.pair.signIn == held {}\n")
        found = ca.sign_in_findings([source(APP + "Backend/Sync/X.swift", text),
                                     source(APP + "Account/X.swift", text)])
        self.assertEqual([(f.path, f.line, f.rule) for f in found],
                         [(APP + "Backend/Sync/X.swift", n, "sign-in-compare") for n in (1, 2, 3, 8, 9, 10, 11, 12)])

    def test_a_flag_or_a_type_named_like_a_sign_in_is_not_a_comparison(self) -> None:
        text = ("if needsSignIn == true {}\nif false != didSignIn {}\nlet ticket = Ticket(seat: 3)\n"
                "let t = session.ticket\nif isSigningIn == false {}\nif route == Route.signIn {}\n"
                "if Route.signIn != route {}\nif (.signIn == step) {}\nif step == .signIn {}\n")
        self.assertEqual(ca.sign_in_findings([source(APP + "Backend/Sync/X.swift", text)]), [])

    def test_a_setter_that_reads_the_current_sign_in_fails_everywhere(self) -> None:
        text = ("var name: String {\n    get { stored }\n    set { prefs.change(for: session.currentSignIn) { _ in } }\n}\n"
                "var term = \"\" {\n    didSet { pick(term, for: AccountSession.school.currentSignIn) }\n}\n"
                "var flag: Binding<Bool> {\n    Binding(get: { on }, set: { turn($0, for: session.currentSignIn) })\n}\n"
                "func set(_ value: Int, for signIn: SignIn) { write(value, for: signIn) }\n")
        found = [f for f in ca.sign_in_findings([source(APP + "Features/X.swift", text)]) if f.rule == "sign-in-in-setter"]
        self.assertEqual([f.line for f in found], [3, 6])

    def test_a_cleanup_gated_on_the_sign_in_fails_everywhere(self) -> None:
        text = ("func load() async {\n    defer { if signIn.isCurrent { loading = nil } }\n"
                "    defer { if running == load { loading = nil } }\n    guard signIn.isCurrent else { return }\n}\n")
        found = [f for f in ca.sign_in_findings([source(APP + "Account/X.swift", text)]) if f.rule == "sign-in-in-cleanup"]
        self.assertEqual([f.line for f in found], [2])

    def test_an_account_file_type_outside_its_store_fails(self) -> None:
        text = "let id = MoodleFiles.shared.lookupMoodleCourseId(idnumber: n)\n"
        found = ca.account_store_findings([source(APP + "Backend/Sync/X.swift", text),
                                           source(APP + "Stores/Moodle/X.swift", text),
                                           source(APP + "Migrations/X.swift", text)], "")
        self.assertEqual([(f.path, f.rule) for f in found], [(APP + "Backend/Sync/X.swift", "account-store-write")])

    def test_an_account_key_written_or_reset_outside_the_file_that_clears_it_fails(self) -> None:
        inventory = ("| defaults | `syncedOnce` | school | `swift/TigerDuck/Backend/Sync/Progress.swift` `forget` |\n"
                     "| defaults | `theme` | device |  |\n")
        text = ("let seen = Defaults[.syncedOnce]\nDefaults[.syncedOnce, for: signIn] = true\n"
                "Defaults[.syncedOnce, for: signIn].insert(x)\nDefaults.reset(.syncedOnce)\n"
                "change(&Defaults[.syncedOnce, for: signIn])\nDefaults[.theme] = 1\n"
                "Defaults[AccountKeys.syncedOnce, for: signIn] = true\nDefaults.reset(.theme, .syncedOnce)\n"
                "if Defaults[.syncedOnce].contains(x) {}\nlet n = Defaults[AccountKeys.syncedOnce].count\n")
        found = ca.account_store_findings([source(APP + "Backend/Sync/FullSync.swift", text),
                                           source(APP + "Backend/Sync/Progress.swift", text)], inventory)
        self.assertEqual([(f.path, f.line, f.rule) for f in found],
                         [(APP + "Backend/Sync/FullSync.swift", n, "account-store-write") for n in (2, 3, 4, 5, 7, 8)])

    def test_a_writable_mail_store_outside_the_mail_store_fails(self) -> None:
        text = ("let store = MailSettingsStore(defaults: suite)\nlet fields = prefs as? MailPreferenceFields\n"
                "final class Fake: MailPreferenceFields {}\nif MailSettingsStore.shared.studentID == id {}\n"
                "prefs.change(for: signIn) { (fields: any MailPreferenceFields) in fields.studentID = id }\n"
                "let name = MailSettingsStore.shared.displayName\nlet s = MailSettingsStore.shared as? MailSettingsStore\n")
        found = ca.account_store_findings([source(APP + "Mail/Sync/X.swift", text),
                                           source(APP + "Mail/Store/X.swift", text)], "")
        self.assertEqual([(f.path, f.line, f.rule) for f in found],
                         [(APP + "Mail/Sync/X.swift", n, "account-store-write") for n in (1, 2, 3, 7)])


if __name__ == "__main__":
    unittest.main()
