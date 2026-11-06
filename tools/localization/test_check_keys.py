import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_keys  # noqa: E402


def keys_in(*sources: str) -> dict[str, list[int]]:
    """key -> lines for Swift sources, as if they were shipping files."""
    with tempfile.TemporaryDirectory() as tmp:
        files = []
        for index, source in enumerate(sources):
            path = Path(tmp) / f"F{index}.swift"
            path.write_text(source, encoding="utf-8")
            files.append(path)
        saved = check_keys.ROOT
        check_keys.ROOT = Path(tmp)
        try:
            found = check_keys.referenced_keys(files)
        finally:
            check_keys.ROOT = saved
    return {k: [int(s.rsplit(":", 1)[1]) for s in v] for k, v in found.items()}


class ReferencedKeysTests(unittest.TestCase):
    def test_reads_the_four_original_shapes(self):
        src = '''
let a = String(localized: "k_one")
let b = LocalizedStringKey("k_two")
let c = NSLocalizedString("k_three", comment: "")
let d = Text("k_four")
'''
        self.assertEqual(set(keys_in(src)), {"k_one", "k_two", "k_three", "k_four"})

    def test_multi_line_call_reports_the_literal_line(self):
        src = 'let a = String(\n    localized:\n        "split_key"\n)\n'
        self.assertEqual(keys_in(src), {"split_key": [3]})

    def test_commented_out_call_is_ignored(self):
        src = '// String(localized: "gone_line")\n/* Text("gone_block") */\nlet a = 1\n'
        self.assertEqual(keys_in(src), {})

    def test_display_text_in_swiftui_position_is_not_a_key(self):
        src = 'Text("GPA %.2f")\nText("\\u2014")\nLabel("Hello", systemImage: "x")\nText("plain")\n'
        self.assertEqual(keys_in(src), {})

    def test_swiftui_views_and_modifiers(self):
        src = '''
Label("label_key", systemImage: "star")
Button("button_key") {}
Toggle("toggle_key", isOn: $on)
Section("section_key") {}
Picker("picker_key", selection: $s) {}
Link("link_key", destination: u)
Menu("menu_key") {}
NavigationLink("nav_key") {}
TextField("field_key", text: $t)
LabeledContent("labeled_key", value: v)
ContentUnavailableView("empty_key", systemImage: "x")
view.navigationTitle("title_key")
view.alert("alert_key", isPresented: $p) {}
view.confirmationDialog("dialog_key", isPresented: $p) {}
view.help("help_key")
view.accessibilityLabel("a11y_key")
view.searchable(text: $q, prompt: "prompt_key")
'''
        self.assertEqual(len(keys_in(src)), 17)

    def test_accessibility_identifier_is_not_a_key(self):
        self.assertEqual(keys_in('view.accessibilityIdentifier("some_id")\n'), {})

    def test_ternary_reads_both_branches_not_the_condition(self):
        src = 'let a = String(localized: mode == "a_b" ? "yes_key" : "no_key")\n'
        self.assertEqual(set(keys_in(src)), {"yes_key", "no_key"})

    def test_literal_inside_interpolation_and_nested_call(self):
        src = 'let a = "\\(String(localized: "inner_key"))"\nlet b = String(localized: "x_\\(n)")\n'
        self.assertEqual(set(keys_in(src)), {"inner_key"})

    def test_helper_with_localization_value_parameter(self):
        src = '''
func linkRow(_ key: String.LocalizationValue, url: URL) {}
func fieldLabel(_ key: String.LocalizationValue) -> String { "" }
linkRow("row_key", url: u)
fieldLabel("field_label_key")
'''
        self.assertEqual(set(keys_in(src)), {"row_key", "field_label_key"})

    def test_helper_with_resource_parameter(self):
        src = '''
struct L {
    func string(_ key: LocalizedStringResource) -> String { "" }
    func format(_ key: LocalizedStringResource, _ args: CVarArg...) -> String { "" }
}
func swatch(hex: Int, nameKey: LocalizedStringResource) {}
language.string("string_key")
language.format("format_key", 1)
swatch(hex: 1, nameKey: "swatch_key")
'''
        self.assertEqual(set(keys_in(src)), {"string_key", "format_key", "swatch_key"})

    def test_key_argument_label_from_stored_property(self):
        src = '''
struct Row { let titleKey: String.LocalizationValue }
struct Repo { let descriptionKey: LocalizedStringResource }
Row(titleKey: "title_prop_key")
Repo(descriptionKey: "description_prop_key")
'''
        self.assertEqual(set(keys_in(src)), {"title_prop_key", "description_prop_key"})

    def test_a_static_property_is_no_argument_label(self):
        src = '''
struct OpenPass: OpenIntent { static let title: LocalizedStringResource = "static_title_key" }
struct Row { static let height = 44; let nameKey: LocalizedStringResource }
Section(title: "IMAP", value: 993)
Row(nameKey: "row_name_key")
'''
        self.assertEqual(set(keys_in(src)), {"static_title_key", "row_name_key"})

    def test_a_static_on_the_line_before_its_let_is_still_static(self):
        src = '''
struct OpenPass: OpenIntent {
    static
    let title: LocalizedStringResource = "static_title_key"
}
struct Row {
    static let height = 44
    let nameKey: LocalizedStringResource
}
Section(title: "IMAP", value: 993)
Row(nameKey: "row_name_key")
'''
        self.assertEqual(set(keys_in(src)), {"static_title_key", "row_name_key"})

    def test_a_commented_out_static_keeps_the_label(self):
        src = '''
struct Row { /* static */ let nameKey: LocalizedStringResource }
Row(nameKey: "row_name_key")
'''
        self.assertEqual(set(keys_in(src)), {"row_name_key"})

    def test_key_held_in_a_plain_string_is_not_read(self):
        src = '''
struct Repo { let descriptionKey: String }
func show(_ r: Repo) -> some View { Text(LocalizedStringKey(r.descriptionKey)) }
func string(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: nil) }
func weekdayKey(_ day: Int) -> String { day == 1 ? "string_mon" : "string_tue" }
static let colors: [(nameKey: String, hex: Int)] = [("string_color", 0x007AFF)]
Repo(descriptionKey: "string_description")
string("string_helper")
'''
        self.assertEqual(keys_in(src), {})

    def test_function_returns(self):
        src = '''
private func weekdayKey(_ weekday: Int) -> LocalizedStringResource {
    switch weekday {
    case 1: return "return_mon"
    case 2: "case_tue"
    default:
        "case_sun"
    }
}
func title(_ on: Bool) throws -> LocalizedStringResource { on ? "ternary_on" : "ternary_off" }
func label(_ on: Bool) -> LocalizedStringResource {
    if on { "if_on" } else { "if_off" }
}
func caption() -> LocalizedStringResource {
    guard ready else { return "guard_key" }
    return "plain_return"
}
'''
        self.assertEqual(
            set(keys_in(src)),
            {"return_mon", "case_tue", "case_sun", "ternary_on", "ternary_off", "if_on", "if_off",
             "guard_key", "plain_return"},
        )

    def test_computed_property_returns_and_their_lines(self):
        src = 'enum E {\n    var title: LocalizedStringResource {\n        switch self {\n        case .a: "prop_a"\n        case .b: return "prop_b"\n        }\n    }\n}\n'
        self.assertEqual(keys_in(src), {"prop_a": [4], "prop_b": [5]})

    def test_other_literals_in_a_returning_body_are_not_read(self):
        src = '''
func key(_ code: String) -> LocalizedStringResource {
    switch code {
    case "pattern_one", "pattern_two": return "matched_key"
    default: break
    }
    let local = "local_value"
    if code == "compared_value" { return "branch_key" }
    log("logged_value")
    return code + "_suffix"
}
'''
        self.assertEqual(set(keys_in(src)), {"matched_key", "branch_key"})

    def test_localized_string_key_returns_read_snake_case_only(self):
        src = 'var title: LocalizedStringKey { flag ? "lsk_title" : "Hello %@" }\n'
        self.assertEqual(set(keys_in(src)), {"lsk_title"})

    def test_tables_of_resources(self):
        src = '''
static let colors: [(nameKey: LocalizedStringResource, hex: Int)] = [
    ("color_one", 0x007AFF),
    ("color_two", 0xAF52DE),
]
private static let captionKeys: [LocalizedStringResource] = [
    "caption_mon", "caption_tue",
]
let byDay: [Int: LocalizedStringResource] = [1: "day_one", 2: "day_two"]
let empty: LocalizedStringResource = isEmpty ? "scalar_empty" : "scalar_full"
let ids: [String: Int] = ["not_a_key": 1]
'''
        self.assertEqual(
            set(keys_in(src)),
            {"color_one", "color_two", "caption_mon", "caption_tue", "day_one", "day_two",
             "scalar_empty", "scalar_full"},
        )

    def test_key_built_at_run_time_is_invisible(self):
        self.assertEqual(keys_in('let a = String(localized: String.LocalizationValue(prefix + "_x"))\n'), {})

    def test_triple_quoted_and_raw_strings_do_not_break_scanning(self):
        src = 'let a = """\n  String(localized: "fake_key") // x\n  """\nlet b = #"a "quoted" b"#\nText("real_key")\n'
        self.assertEqual(keys_in(src), {"real_key": [5]})


class MissingKeysTests(unittest.TestCase):
    def test_test_targets_are_skipped(self):
        root = check_keys.ROOT
        shipped = [p.relative_to(root).parts for p in check_keys.shipping_swift_files()]
        self.assertTrue(shipped)
        self.assertFalse([parts for parts in shipped if any(x.endswith("Tests") for x in parts)])


if __name__ == "__main__":
    unittest.main()
