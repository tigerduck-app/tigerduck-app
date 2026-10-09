#!/usr/bin/env python3
"""Check Swift comments against the comment rules in AGENTS.md.

check [--base REF] [--all] [PATH ...]
    Report each comment that breaks a rule as `path:line: rule: message`.
    Without paths it checks the Swift files changed since REF, or every
    tracked Swift file with --all. Given REF, the length rule only reports
    blocks that hold a line added or changed since REF.
same-tokens REF
    Fail when a Swift file in the working tree differs from REF in anything
    but comments.

Exit status: 0 when clean, 1 on findings, 2 on usage or git errors.
`swift/Packages/` (vendored code) is never checked.
"""
import argparse
import bisect
import os
import re
import subprocess
import sys
from collections.abc import Iterator
from dataclasses import dataclass

EXCLUDED_PREFIX = 'swift/Packages/'
REGULAR_LIMIT = 3
DOC_LIMIT = 8

HAN = re.compile('[㐀-鿿豈-﫿]')
TRACE = re.compile(
    r'(?i)fix round \d|dispatch(,? [0-9-]+)? addition|\((critical|important|minor) \d+\)'
    r'|(?<!RFC \d{4} )(?<!RFC \d{3} )§ ?\d')
# An `openspec/` path is the openspec rule's finding, not a second tool finding.
TOOL = re.compile(
    r'(?i)\b(claude|codex|copilot|greptile|coderabbit|superpowers|opencode|sisyphus|bmad|openspec)\b(?!/)')
OPENSPEC_PATH = re.compile(r'(?i)\bopenspec/')
HUNK = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@', re.M)
STRING_OPEN = re.compile(r'(#*)("""|"|/)')
WORD = re.compile(r'\S+')

MESSAGES = {
    'han': 'comment contains Han characters; write comments in English',
    'trace': 'cites a review round, a dispatch or a section of an outside document; state the reason',
    'openspec': 'cites an openspec/ path, which moves when the change is archived; state the reason',
}


class GitError(Exception):
    pass


@dataclass
class Line:
    code: bool = False
    comment: str = ''
    doc: bool = False


@dataclass(frozen=True, order=True)
class Finding:
    path: str
    line: int
    rule: str
    message: str


def lex(src: str) -> list[tuple[str, int, int]]:
    """Split Swift source into (kind, start, end) spans of code, string, comment or doc.

    Handles nested block comments, raw and multi-line strings, interpolation
    holding strings and parentheses, and `#/.../#` regex literals. A bare
    `/.../` regex literal lexes as code, so one holding `//` or a quote would
    be misread.
    """
    spans = []
    n = len(src)
    i = 0
    code_start = 0
    interpolations = []  # [hashes, multiline, open parentheses] per open `\(`

    def flush(upto: int) -> None:
        if upto > code_start:
            spans.append(('code', code_start, upto))

    def scan_string(j: int, hashes: int, multiline: bool, delim: str) -> tuple[int, bool]:
        close = delim * (3 if multiline else 1) + '#' * hashes
        escape = '\\' + '#' * hashes
        while j < n:
            if src.startswith(close, j):
                return j + len(close), False
            if delim == '"' and src.startswith(escape, j):
                k = j + len(escape)
                if k < n and src[k] == '(':
                    return k + 1, True
                j = k + 1
                continue
            if delim == '"' and not multiline and src[j] == '\n':
                return j, False
            j += 1
        return n, False

    def string_from(j: int, hashes: int, multiline: bool, delim: str) -> None:
        nonlocal i, code_start
        end, interpolates = scan_string(j, hashes, multiline, delim)
        spans.append(('string', j, end))
        i = code_start = end
        if interpolates:
            interpolations.append([hashes, multiline, 0])

    while i < n:
        c = src[i]
        if src.startswith('//', i):
            flush(i)
            j = src.find('\n', i)
            j = n if j < 0 else j
            doc = src.startswith('///', i) and not src.startswith('////', i)
            spans.append(('doc' if doc else 'comment', i, j))
            i = code_start = j
            continue
        if src.startswith('/*', i):
            flush(i)
            j, depth = i + 2, 1
            while j < n and depth:
                if src.startswith('/*', j):
                    depth += 1
                    j += 2
                elif src.startswith('*/', j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            doc = src.startswith('/**', i) and not src.startswith('/**/', i)
            spans.append(('doc' if doc else 'comment', i, j))
            i = code_start = j
            continue
        if c in '#"':
            m = STRING_OPEN.match(src, i)
            if m and (m.group(2) != '/' or m.group(1)):
                flush(i)
                spans.append(('string', i, m.end()))
                delim = '/' if m.group(2) == '/' else '"'
                string_from(m.end(), len(m.group(1)), m.group(2) == '"""', delim)
                continue
        if interpolations:
            if c == '(':
                interpolations[-1][2] += 1
            elif c == ')':
                if interpolations[-1][2] == 0:
                    flush(i)
                    hashes, multiline, _ = interpolations.pop()
                    spans.append(('string', i, i + 1))
                    string_from(i + 1, hashes, multiline, '"')
                    continue
                interpolations[-1][2] -= 1
        i += 1
    flush(n)
    return spans


def analyze(src: str) -> list[Line]:
    """Return one Line per source line: whether it holds code, and its comment text."""
    starts = [0] + [m.end() for m in re.finditer('\n', src)]
    lines = [Line() for _ in starts]

    def line_of(pos: int) -> int:
        return bisect.bisect_right(starts, pos) - 1

    for kind, s, e in lex(src):
        if e <= s:
            continue
        first, last = line_of(s), line_of(e - 1)
        if kind in ('comment', 'doc'):
            for number in range(first, last + 1):
                end = starts[number + 1] if number + 1 < len(starts) else len(src)
                lines[number].comment += src[max(s, starts[number]):min(e, end)]
                lines[number].doc = lines[number].doc or kind == 'doc'
        elif kind == 'string':
            for number in range(first, last + 1):
                lines[number].code = True
        else:
            for m in WORD.finditer(src, s, e):
                lines[line_of(m.start())].code = True
    return lines


def blocks(lines: list[Line]) -> Iterator[tuple[int, int, str]]:
    """Yield (first line index, length, kind) for each run of comment-only lines of one kind."""
    start = kind = None
    for number, line in enumerate([*lines, Line()]):
        current = None
        if line.comment and not line.code:
            current = 'doc' if line.doc else 'regular'
        if current != kind:
            if kind:
                yield start, number - start, kind
            start, kind = number, current


def check_source(path: str, src: str, changed: set[int] | None = None) -> list[Finding]:
    """Return the findings for one file; `changed` limits the length rule to those 1-based lines."""
    lines = analyze(src)
    findings = []
    for number, line in enumerate(lines, start=1):
        text = line.comment
        if not text:
            continue
        if HAN.search(text):
            findings.append(Finding(path, number, 'han', MESSAGES['han']))
        if TRACE.search(text):
            findings.append(Finding(path, number, 'trace', MESSAGES['trace']))
        tool = TOOL.search(text)
        if tool:
            message = f'names {tool.group(1)}; comments do not mention agents or tools'
            findings.append(Finding(path, number, 'tool', message))
        if OPENSPEC_PATH.search(text):
            findings.append(Finding(path, number, 'openspec', MESSAGES['openspec']))
    for start, length, kind in blocks(lines):
        limit = DOC_LIMIT if kind == 'doc' else REGULAR_LIMIT
        if length <= limit:
            continue
        if changed is not None and not changed.intersection(range(start + 1, start + length + 1)):
            continue
        message = f'{kind} comment block is {length} lines; the limit is {limit}'
        findings.append(Finding(path, start + 1, 'length', message))
    return findings


def tokens(src: str) -> list[tuple[str, int]]:
    """Return (token, offset) pairs without comments: strings whole, code split on whitespace."""
    out = []
    for kind, s, e in lex(src):
        if kind == 'string':
            out.append((src[s:e], s))
        elif kind == 'code':
            out.extend((m.group(), m.start()) for m in WORD.finditer(src, s, e))
    return out


def first_difference(old: str, new: str) -> int | None:
    """Return the 1-based line in `new` where its tokens start to differ from `old`, or None."""
    old_tokens, new_tokens = tokens(old), tokens(new)
    for index, (before, after) in enumerate(zip(old_tokens, new_tokens)):
        if before[0] != after[0]:
            return new.count('\n', 0, after[1]) + 1
    if len(old_tokens) == len(new_tokens):
        return None
    shorter = min(len(old_tokens), len(new_tokens))
    offset = new_tokens[shorter][1] if shorter < len(new_tokens) else len(new)
    return new.count('\n', 0, offset) + 1


def git(root: str, *args: str) -> str:
    proc = subprocess.run(['git', *args], cwd=root, capture_output=True, text=True,
                          encoding='utf-8', errors='surrogateescape')
    if proc.returncode != 0:
        raise GitError(proc.stderr.strip() or f'git {args[0]} exited {proc.returncode}')
    return proc.stdout


def exists_at(root: str, ref: str, path: str) -> bool:
    proc = subprocess.run(['git', 'cat-file', '-e', f'{ref}:{path}'], cwd=root,
                          capture_output=True)
    return proc.returncode == 0


def verify_ref(root: str, ref: str) -> None:
    git(root, 'rev-parse', '--verify', '--quiet', f'{ref}^{{commit}}')


def split_z(output: str) -> list[str]:
    return [item for item in output.split('\0') if item]


def untracked_swift(root: str) -> list[str]:
    return split_z(git(root, 'ls-files', '-z', '--others', '--exclude-standard', '--', '*.swift'))


def changed_lines(root: str, ref: str, path: str) -> set[int] | None:
    """Return the 1-based lines added or changed since `ref`, or None for a file new since then."""
    if not exists_at(root, ref, path):
        return None
    diff = git(root, 'diff', '-U0', '--no-color', '--no-ext-diff', '--no-textconv', ref, '--', path)
    lines = set()
    for m in HUNK.finditer(diff):
        start, count = int(m.group(1)), int(m.group(2) or 1)
        lines.update(range(start, start + count))
    return lines


def read(root: str, path: str) -> str:
    with open(os.path.join(root, path), encoding='utf-8', errors='surrogateescape') as handle:
        return handle.read()


def escape_annotation(value: str, prop: bool = False) -> str:
    value = value.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
    if prop:
        value = value.replace(':', '%3A').replace(',', '%2C')
    return value


def report(findings: list[Finding]) -> None:
    annotate = os.environ.get('GITHUB_ACTIONS') == 'true'
    for finding in sorted(findings):
        print(f'{finding.path}:{finding.line}: {finding.rule}: {finding.message}')
        if annotate:
            print(f'::error file={escape_annotation(finding.path, True)},line={finding.line},'
                  f'title={escape_annotation(finding.rule, True)}::{escape_annotation(finding.message)}')
    if findings:
        files = len({finding.path for finding in findings})
        print(f'{len(findings)} finding(s) in {files} file(s)', file=sys.stderr)


def paths_to_check(root: str, args: argparse.Namespace,
                   parser: argparse.ArgumentParser) -> list[str]:
    if args.paths:
        paths = []
        real_root = os.path.realpath(root)
        for given in args.paths:
            full = os.path.realpath(given)
            if not os.path.isfile(full):
                parser.error(f'no such file: {given}')
            relative = os.path.relpath(full, real_root)
            if relative.startswith(os.pardir + os.sep):
                continue
            paths.append(relative.replace(os.sep, '/'))
    elif args.all:
        paths = split_z(git(root, 'ls-files', '-z', '--', '*.swift'))
    else:
        changed = git(root, 'diff', '--name-only', '-z', '--no-renames', '--diff-filter=d',
                      args.base, '--', '*.swift')
        paths = split_z(changed) + untracked_swift(root)
    return sorted({path for path in paths
                   if path.endswith('.swift') and not path.startswith(EXCLUDED_PREFIX)})


def run_check(root: str, args: argparse.Namespace, parser: argparse.ArgumentParser) -> int:
    if args.all and args.paths:
        parser.error('--all checks every tracked file; give no paths with it')
    if not (args.base or args.all or args.paths):
        parser.error('give --base REF, --all or paths')
    if args.base:
        verify_ref(root, args.base)
    findings = []
    for path in paths_to_check(root, args, parser):
        changed = changed_lines(root, args.base, path) if args.base else None
        findings.extend(check_source(path, read(root, path), changed))
    report(findings)
    return 1 if findings else 0


def run_same_tokens(root: str, ref: str) -> int:
    verify_ref(root, ref)
    entries = split_z(git(root, 'diff', '--name-status', '-z', '--no-renames', ref, '--', '*.swift'))
    statuses = dict(zip(entries[1::2], entries[0::2]))
    for path in untracked_swift(root):
        statuses[path] = 'A'
    problems = []
    for path in sorted(statuses):
        status = statuses[path]
        if status == 'A':
            problems.append(f'{path}: added since {ref}')
        elif status == 'D':
            problems.append(f'{path}: deleted since {ref}')
        else:
            line = first_difference(git(root, 'show', f'{ref}:{path}'), read(root, path))
            if line:
                problems.append(f'{path}:{line}: code differs from {ref}')
    for problem in problems:
        print(problem)
    if problems:
        return 1
    print(f'{len(statuses)} changed Swift file(s), comments only')
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog='check_comments.py',
                                     description='Check Swift comments against the comment rules.')
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('check', help='report comments that break a rule')
    check.add_argument('--base', metavar='REF', help='check files and blocks changed since REF')
    check.add_argument('--all', action='store_true', help='check every tracked Swift file')
    check.add_argument('paths', nargs='*', metavar='PATH')
    same = commands.add_parser('same-tokens', help='fail when code changed since REF')
    same.add_argument('ref', metavar='REF')
    args = parser.parse_args(argv)
    try:
        root = git(os.getcwd(), 'rev-parse', '--show-toplevel').strip()
        if args.command == 'check':
            return run_check(root, args, check)
        return run_same_tokens(root, args.ref)
    except GitError as error:
        print(f'check_comments.py: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
