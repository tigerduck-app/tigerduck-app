"""Tests for tools/check_comments.py: python3 -m unittest discover -s tools -p 'test_*.py'"""
import os
import subprocess
import sys
import tempfile
import unittest

import check_comments as cc

CHECKER = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'check_comments.py')
HAN_TEXT = '中文'
SECTION = '§'


def kinds(src: str) -> list[tuple[str, str]]:
    return [(kind, src[s:e]) for kind, s, e in cc.lex(src) if kind != 'code']


def comments(src: str) -> list[str]:
    return [text for kind, text in kinds(src) if kind in ('comment', 'doc')]


def rules(src: str, changed: set[int] | None = None) -> list[tuple[int, str]]:
    return [(f.line, f.rule) for f in cc.check_source('x.swift', src, changed)]


def block(prefix: str, count: int) -> str:
    return ''.join(f'{prefix} line {n}\n' for n in range(count))


class LexerTests(unittest.TestCase):
    def test_nested_block_comment_is_one_comment(self) -> None:
        src = 'let a = 1 /* outer /* inner */ still outer */ let b = 2'
        self.assertEqual(comments(src), ['/* outer /* inner */ still outer */'])

    def test_raw_string_holds_quotes_and_slashes(self) -> None:
        src = 'let s = #"say "hi" // not a comment"# // real'
        self.assertEqual(comments(src), ['// real'])

    def test_raw_string_interpolation(self) -> None:
        src = 'let s = #"a \\#(f("x")) // no"# // yes'
        self.assertEqual(comments(src), ['// yes'])

    def test_multiline_string_is_not_a_comment(self) -> None:
        src = 'let s = """\n// not a comment\n/* nor this */\n"""\n// comment\n'
        self.assertEqual(comments(src), ['// comment'])

    def test_interpolation_holding_strings_and_parentheses(self) -> None:
        src = 'let s = "\\(f(")", g((1)))) // in string" // after'
        self.assertEqual(comments(src), ['// after'])

    def test_extended_regex_literal(self) -> None:
        src = 'let r = #/a"b//c/# // after'
        self.assertEqual(comments(src), ['// after'])

    def test_slashes_inside_a_string(self) -> None:
        src = 'let url = "https://example.com/*path*/" // site'
        self.assertEqual(comments(src), ['// site'])

    def test_escaped_quote_does_not_end_a_string(self) -> None:
        src = 'let s = "a \\" // b" // c'
        self.assertEqual(comments(src), ['// c'])

    def test_doc_and_regular_kinds(self) -> None:
        cases = {'/// doc': 'doc', '//// four': 'comment', '/** doc */': 'doc',
                 '/**/': 'comment', '// plain': 'comment', '/* plain */': 'comment'}
        for src, kind in cases.items():
            with self.subTest(src=src):
                self.assertEqual(kinds(src), [(kind, src)])


class RuleTests(unittest.TestCase):
    def test_han_in_comment(self) -> None:
        self.assertEqual(rules(f'let a = 1 // {HAN_TEXT}\n'), [(1, 'han')])

    def test_han_in_string_literal_is_fine(self) -> None:
        self.assertEqual(rules(f'let a = "{HAN_TEXT}" // English\n'), [])

    def test_trace_patterns(self) -> None:
        for text in ('fix round 1', '(important 4)', 'dispatch addition 3',
                     'dispatch, 2026-09-16 addition 1', f'spec {SECTION}6', f'design doc {SECTION}9.3'):
            with self.subTest(text=text):
                self.assertEqual(rules(f'// {text}\n'), [(1, 'trace')])

    def test_rfc_sections_are_allowed(self) -> None:
        for text in (f'RFC 5322 {SECTION}3.6', f'RFC 822 {SECTION}4', f'RFC 3501 {SECTION} 6.3'):
            with self.subTest(text=text):
                self.assertEqual(rules(f'// {text}\n'), [])

    def test_tool_names(self) -> None:
        for name in ('Claude', 'codex', 'Greptile', 'superpowers', 'OpenSpec'):
            with self.subTest(name=name):
                found = cc.check_source('x.swift', f'// asked {name} about it\n')
                self.assertEqual([(f.rule, f.message.split(';')[0]) for f in found],
                                 [('tool', f'names {name}')])

    def test_openspec_path_is_one_finding(self) -> None:
        self.assertEqual(rules('// see openspec/changes/x/design.md\n'), [(1, 'openspec')])

    def test_rules_ignore_code_and_strings(self) -> None:
        self.assertEqual(rules('let claude = "fix round 1 openspec/"\n'), [])

    def test_regular_limit(self) -> None:
        self.assertEqual(rules(block('//', 3)), [])
        self.assertEqual(rules(block('//', 4)), [(1, 'length')])

    def test_doc_limit(self) -> None:
        self.assertEqual(rules(block('///', 8)), [])
        self.assertEqual(rules('let a = 1\n' + block('///', 9)), [(2, 'length')])

    def test_block_comment_lines_count(self) -> None:
        self.assertEqual(rules('/*\n a\n\n b\n*/\n'), [(1, 'length')])

    def test_kinds_and_trailing_comments_split_blocks(self) -> None:
        src = block('///', 8) + block('//', 3) + 'let a = 1 // one\nlet b = 2 // two\n' + block('//', 3)
        self.assertEqual(rules(src), [])

    def test_changed_lines_limit_the_length_rule(self) -> None:
        src = block('//', 5) + 'let a = 1\n' + block('//', 5)
        self.assertEqual(rules(src, changed={8}), [(7, 'length')])
        self.assertEqual(rules(src, changed={6}), [])
        self.assertEqual(rules(src), [(1, 'length'), (7, 'length')])


class TokenTests(unittest.TestCase):
    def test_comment_edits_keep_tokens(self) -> None:
        old = 'let a = 1 // old\n/* long\n block */\nlet b = "x // y"\n'
        new = 'let a = 1 // new\nlet b = "x // y"\n'
        self.assertIsNone(cc.first_difference(old, new))

    def test_code_and_string_edits_change_tokens(self) -> None:
        old = 'let a = 1\nlet b = "x"\n'
        self.assertEqual(cc.first_difference(old, 'let a = 2\nlet b = "x"\n'), 1)
        self.assertEqual(cc.first_difference(old, 'let a = 1\nlet b = "y"\n'), 2)
        self.assertEqual(cc.first_difference(old, 'let a = 1\n'), 2)


class CommandLineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = self.temp.name
        self.git('init', '-q')

    def tearDown(self) -> None:
        self.temp.cleanup()

    def git(self, *args: str) -> None:
        subprocess.run(['git', '-c', 'user.name=test', '-c', 'user.email=test@example.com',
                        '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', *args],
                       cwd=self.root, check=True, capture_output=True)

    def write(self, path: str, text: str) -> None:
        full = os.path.join(self.root, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, 'w', encoding='utf-8') as handle:
            handle.write(text)

    def commit(self) -> None:
        self.git('add', '-A')
        self.git('commit', '-qm', 'commit')

    def run_checker(self, *args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        environment = {**os.environ, 'GITHUB_ACTIONS': 'false', **(env or {})}
        return subprocess.run([sys.executable, CHECKER, *args], cwd=self.root,
                              capture_output=True, text=True, env=environment)

    def test_only_the_changed_block_is_reported(self) -> None:
        self.write('a.swift', block('///', 12) + 'let a = 1\n' + block('///', 12) + 'let b = 2\n')
        self.commit()
        self.write('a.swift', block('///', 12) + 'let a = 1\n/// edited\n' + block('///', 11) + 'let b = 2\n')
        result = self.run_checker('check', '--base', 'HEAD')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.splitlines(),
                         ['a.swift:14: length: doc comment block is 12 lines; the limit is 8'])

    def test_untouched_files_and_blocks_pass(self) -> None:
        self.write('a.swift', block('//', 6))
        self.commit()
        self.write('b.swift', 'let b = 1\n')
        result = self.run_checker('check', '--base', 'HEAD')
        self.assertEqual((result.returncode, result.stdout), (0, ''))

    def test_new_file_counts_as_changed(self) -> None:
        self.write('a.swift', 'let a = 1\n')
        self.commit()
        self.write('new.swift', block('//', 4))
        result = self.run_checker('check', '--base', 'HEAD')
        self.assertIn('new.swift:1: length:', result.stdout)

    def test_paths_without_base_check_every_block(self) -> None:
        self.write('a.swift', block('//', 4))
        self.commit()
        self.assertEqual(self.run_checker('check', 'a.swift').returncode, 1)

    def test_vendored_packages_are_skipped(self) -> None:
        self.write('swift/Packages/Lib/a.swift', block('//', 9))
        self.commit()
        self.assertEqual(self.run_checker('check', '--all').returncode, 0)

    def test_annotations_on_github_actions(self) -> None:
        self.write('a.swift', '// fix round 1\n')
        self.commit()
        result = self.run_checker('check', '--all', env={'GITHUB_ACTIONS': 'true'})
        self.assertIn('::error file=a.swift,line=1,title=trace::', result.stdout)

    def test_usage_and_git_errors_exit_2(self) -> None:
        self.write('a.swift', 'let a = 1\n')
        self.commit()
        self.assertEqual(self.run_checker('check').returncode, 2)
        self.assertEqual(self.run_checker('check', '--all', 'a.swift').returncode, 2)
        self.assertEqual(self.run_checker('check', '--base', 'no-such-ref').returncode, 2)

    def test_same_tokens(self) -> None:
        self.write('a.swift', 'let a = 1 // old\n')
        self.commit()
        self.write('a.swift', '// new\nlet a = 1\n')
        self.assertEqual(self.run_checker('same-tokens', 'HEAD').returncode, 0)
        self.write('a.swift', 'let a = 2\n')
        result = self.run_checker('same-tokens', 'HEAD')
        self.assertEqual((result.returncode, result.stdout), (1, 'a.swift:1: code differs from HEAD\n'))

    def test_same_tokens_reports_added_files(self) -> None:
        self.write('a.swift', 'let a = 1\n')
        self.commit()
        self.write('b.swift', '// only a comment\n')
        result = self.run_checker('same-tokens', 'HEAD')
        self.assertEqual((result.returncode, result.stdout), (1, 'b.swift: added since HEAD\n'))


if __name__ == '__main__':
    unittest.main()
