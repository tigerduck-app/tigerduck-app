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

    def test_helper_with_string_key_parameter_used_to_localize(self):
        src = '''
struct L {
    func string(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: nil) }
    func format(_ key: String, _ args: CVarArg...) -> String { String(format: string(key)) }
}
language.string("string_key")
language.format("format_key", 1)
'''
        self.assertEqual(set(keys_in(src)), {"string_key", "format_key"})

    def test_string_key_parameter_that_is_not_localized_is_ignored(self):
        src = 'func delete(key: String) { store.remove(key) }\ndelete(key: "push_user_id")\n'
        self.assertEqual(keys_in(src), {})

    def test_key_argument_label_from_stored_property_and_parameter(self):
        src = '''
struct Row { let titleKey: String.LocalizationValue }
struct Repo { let descriptionKey: String }
func show(_ r: Repo) -> some View { Text(LocalizedStringKey(r.descriptionKey)) }
Row(titleKey: "title_prop_key")
Repo(descriptionKey: "description_prop_key")
'''
        self.assertEqual(set(keys_in(src)), {"title_prop_key", "description_prop_key"})

    def test_table_of_keys(self):
        src = '''
static let colors: [(nameKey: String, hex: Int)] = [
    ("color_one", 0x007AFF),
    ("color_two", 0xAF52DE),
]
func name(_ c: (nameKey: String, hex: Int)) -> String { String(localized: String.LocalizationValue(c.nameKey)) }
'''
        self.assertEqual(set(keys_in(src)), {"color_one", "color_two"})

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
