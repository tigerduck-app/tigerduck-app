#!/usr/bin/env python3
"""Fail when a shared rule is written again outside its home, or a type outgrows its budget.

Each rule names the phase of the v4 refactor that turns it on. Rules of a phase at or below
ENFORCED_PHASE fail the run; the others are counted, so the work left stays visible without
failing anything yet. Every finding prints as
`path:line: rule: message`, and the message names the home to use instead.

The scope is the Swift sources of the TigerDuck app target, as tools/check_macos_sources.py works
them out, and of swift/Packages/TigerDuckCore/Sources; tests are left out.

Run manually:  python3 tools/check_architecture.py [--report]
    --report lists every finding, those of later phases too.
"""

from __future__ import annotations

import re
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

import check_macos_sources as macos

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "tests.yaml"
TESTS_DIR = "swift/TigerDuckTests/"
APP = "swift/TigerDuck/"
CORE = "swift/Packages/TigerDuckCore/"
CORE_SOURCES = CORE + "Sources/"
# App-target files that belong to an extension's folder; they read the App Group's defaults.
EXTENSION_FOLDERS = ("swift/TigerDuckWidgets/", "swift/TigerDuckLiveActivity/", "swift/TigerDuckWatchWidget/")

ENFORCED_PHASE = 0

TYPE_LINES = 250
VIEW_LINES = 200
FILE_LINES = 400
STORED_PROPERTIES = 10


@dataclass(frozen=True)
class Rule:
    name: str
    phase: int


RULES = {r.name: r for r in (
    Rule("taipei-zone", 0),
    Rule("duplicate-base-name", 0),
    Rule("on-screen-test", 0),
    Rule("login-generation", 2),
    Rule("data-did-update", 3),
    Rule("is-updating-from-network", 3),
    Rule("user-defaults", 3),
    Rule("url-session", 4),
    Rule("type-size", 6),
    Rule("stored-properties", 6),
    Rule("file-size", 6),
    Rule("feature-layering", 6),
    Rule("task-sleep", 7),
)}


@dataclass(frozen=True)
class Finding:
    path: str
    line: int
    rule: str
    message: str

    def __str__(self) -> str:
        return f"{self.path}:{self.line}: {self.rule}: {self.message}"


# (rule, pattern on code with comments and strings blanked, path prefixes it may appear under,
# message naming the home).
PATTERNS = (
    ("login-generation", r"\b(?:loginGeneration|signInGeneration)\b|\.generation\b", (APP + "Account/",),
     "a login generation compared outside Account/; ask `AccountSession` (Account/AccountSession.swift)"),
    ("data-did-update", r"\bdataDidUpdate\b", (),
     "`dataDidUpdate`; observe `Stores/CourseStore.swift` or `Stores/AssignmentStore.swift`"),
    ("is-updating-from-network", r"\bisUpdatingFromNetwork\b", (),
     "`isUpdatingFromNetwork`; edits go through `Stores/CourseStore.swift` and `Stores/AssignmentStore.swift`"),
    ("user-defaults", r"\bUserDefaults\.standard\b|\bUserDefaults\(suiteName:",
     (APP + "Persistence/",) + EXTENSION_FOLDERS,
     "UserDefaults outside Persistence/; read and write through `Persistence/`"),
    ("url-session", r"\bURLSession\(", (APP + "School/NTUST/", APP + "Backend/Client/", APP + "Mail/Transport/"),
     "a URLSession created outside School/NTUST/, Backend/Client/ and Mail/Transport/; use "
     "`NTUSTSessionManager`, `BackendClient` or the mail transport"),
    ("task-sleep", r"\bTask\.sleep\b", (APP + "Support/Clock/", APP + "Support/Concurrency/"),
     "`Task.sleep` outside Support/Clock/ and Support/Concurrency/; wait with `AppClock.sleep(until:)` "
     "or `StateSignal`"),
)
TAIPEI = re.compile(r'"Asia/Taipei"')
STRING_OPEN = re.compile(r'(#*)("""|")')
LAYERS = ("School/", "Backend/", "Persistence/")

# Swift parsing: comments and string contents are blanked first, so braces count only in code.
DECL = re.compile(
    r"^(?P<mods>(?:(?:@[\w.]+(?:\([^)]*\))?|public|private|fileprivate|internal|open|final|"
    r"nonisolated|indirect|package)\s+)*)"
    r"(?P<kind>class|struct|enum|actor|protocol|extension)\s+(?P<name>[A-Za-z_][\w.]*)"
    r"(?P<generic><[^>{]*>)?\s*(?::\s*(?P<inherits>[^{]+?))?\s*(?:where[^{]*)?\{")
PROP = re.compile(
    r"^(?P<mods>(?:(?:@[\w.]+(?:\([^)]*\))?|public|private|fileprivate|internal|open|final|"
    r"static|class|override|lazy|weak|unowned(?:\((?:safe|unsafe)\))?|nonisolated(?:\(unsafe\))?|"
    r"dynamic|"
    r"private\(set\)|fileprivate\(set\)|internal\(set\)|public\(set\))\s+)*)"
    r"(?P<kw>let|var)\s+(?P<name>[A-Za-z_]\w*)\s*(?::\s*(?P<type>[^={]+?))?\s*(?P<tail>[={].*)?$")


def strip_code(text: str) -> str:
    """Blanks comments and string contents, keeping line breaks and the braces of code."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        elif c in '#"':
            m = STRING_OPEN.match(text, i)
            if not m:
                out.append(c)
                i += 1
                continue
            hashes, quote = m.group(1), m.group(2)
            close = quote + hashes
            j = i + len(m.group(0))
            while j < n:
                if not hashes and text[j] == "\\" and j + 1 < n:
                    if text[j + 1] == "(":
                        k, d = j + 2, 1
                        while k < n and d:
                            d += {"(": 1, ")": -1}.get(text[k], 0)
                            k += 1
                        j = k
                        continue
                    j += 2
                    continue
                if text.startswith(close, j):
                    j += len(close)
                    break
                if quote == '"' and text[j] == "\n":
                    break
                j += 1
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def logical_lines(code: str):
    """(line number, text, depth before) per line, joining a line whose parentheses stay open."""
    depth, buf, start, before = 0, "", 0, 0
    for no, line in enumerate(code.split("\n"), 1):
        s = line.strip()
        if not buf:
            start, before = no, depth
        buf = f"{buf} {s}".strip() if buf else s
        depth += line.count("{") - line.count("}")
        if buf.count("(") > buf.count(")") and len(buf) < 2000:
            continue
        yield start, buf, before
        buf = ""


@dataclass
class Decl:
    key: str
    kind: str
    path: str
    start: int
    end: int
    inherits: list[str]
    parent: "Decl | None" = None
    children: list["Decl"] = field(default_factory=list)
    stored: int = 0

    @property
    def own_lines(self) -> int:
        nested = sum(c.end - c.start + 1 for c in self.children if c.kind != "extension")
        return self.end - self.start + 1 - nested


def declarations(path: str, code: str) -> list[Decl]:
    lines = code.split("\n")
    offsets = [0]
    for line in lines:
        offsets.append(offsets[-1] + len(line) + 1)
    found: list[Decl] = []
    stack: list[tuple[Decl, int]] = []
    for no, text, before in logical_lines(code):
        while stack and (before < stack[-1][1] or no > stack[-1][0].end):
            stack.pop()
        m = DECL.match(text)
        if m:
            pos = code.find("{", offsets[no - 1])
            depth, i = 0, pos
            while i < len(code):
                depth += {"{": 1, "}": -1}.get(code[i], 0)
                if depth == 0:
                    break
                i += 1
            parent = stack[-1][0] if stack else None
            name = m.group("name")
            key = name if m.group("kind") == "extension" or parent is None else f"{parent.key}.{name}"
            inherits = [x.strip() for x in re.split(r",(?![^<]*>)", m.group("inherits") or "") if x.strip()]
            decl = Decl(key, m.group("kind"), path, no, code.count("\n", 0, i) + 1, inherits, parent)
            if parent:
                parent.children.append(decl)
            found.append(decl)
            stack.append((decl, before + 1))
            continue
        if not stack or before != stack[-1][1]:
            continue
        owner = stack[-1][0]
        pm = PROP.match(text)
        if pm and owner.kind in ("class", "actor"):
            mods, tail = pm.group("mods") or "", pm.group("tail") or ""
            computed = tail.startswith("{") and not re.match(r"\{\s*(didSet|willSet)", tail)
            if not computed and not re.search(r"\b(static|class)\b", mods):
                owner.stored += 1
    return found


@dataclass
class Source:
    path: str
    text: str
    code: str


def scope_paths(root: Path = ROOT) -> list[str]:
    text = (root / macos.PBXPROJ.relative_to(macos.ROOT)).read_text(encoding="utf-8")
    app = macos.tracked_target_sources(text, root)
    core = subprocess.run(["git", "-C", str(root), "ls-files", f"{CORE_SOURCES}*.swift"],
                          capture_output=True, text=True, check=True).stdout.split("\n")
    return sorted(set(app) | {p for p in core if p})


def load(root: Path, paths: list[str]) -> list[Source]:
    out = []
    for path in paths:
        text = (root / path).read_text(encoding="utf-8")
        out.append(Source(path, text, strip_code(text)))
    return out


def line_of(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def pattern_findings(sources: list[Source]) -> list[Finding]:
    found = []
    for src in sources:
        for m in TAIPEI.finditer(src.text):
            if not src.path.startswith(CORE):
                found.append(Finding(src.path, line_of(src.text, m.start()), "taipei-zone",
                                     '"Asia/Taipei" outside TigerDuckCore; use `TaipeiTime` in TigerDuckCore'))
        for rule, pattern, allowed, message in PATTERNS:
            if allowed and src.path.startswith(allowed):
                continue
            for m in re.finditer(pattern, src.code):
                found.append(Finding(src.path, line_of(src.code, m.start()), rule, message))
    return found


def base_name_findings(paths: list[str]) -> list[Finding]:
    app = [p for p in paths if not p.startswith(CORE)]
    names = Counter(Path(p).name for p in app)
    found = []
    for path in app:
        if names[Path(path).name] > 1:
            others = ", ".join(p for p in app if Path(p).name == Path(path).name and p != path)
            found.append(Finding(path, 1, "duplicate-base-name",
                                 f"shares its base name with {others}; the macOS source arrays match by "
                                 "file name, so rename one (tools/check_macos_sources.py)"))
    return found


def test_code(root: Path) -> str:
    tests = subprocess.run(["git", "-C", str(root), "ls-files", f"{TESTS_DIR}*.swift"],
                           capture_output=True, text=True, check=True).stdout.split("\n")
    return "\n".join(strip_code((root / p).read_text(encoding="utf-8")) for p in tests if p)


def on_screen_findings(workflow: str, code: str) -> list[Finding]:
    """Each `on_screen_tests` entry of the workflow names a test type and function that exist."""
    types = set(re.findall(r"\b(?:class|struct|enum|actor|extension)\s+([A-Za-z_]\w*)", code))
    functions = set(re.findall(r"\bfunc\s+([A-Za-z_]\w*)", code))
    found = []
    lines = workflow.split("\n")
    for no, line in enumerate(lines, 1):
        if not line.strip().startswith("on_screen_tests: >-"):
            continue
        indent = len(line) - len(line.lstrip())
        for offset, entry in enumerate(lines[no:], no + 1):
            if not entry.strip() or len(entry) - len(entry.lstrip()) <= indent:
                break
            parts = entry.strip().split("/")
            type_name = parts[1] if len(parts) > 1 else ""
            function = parts[2].split("(")[0] if len(parts) > 2 else None
            if type_name not in types:
                found.append(Finding(WORKFLOW.relative_to(ROOT).as_posix(), offset, "on-screen-test",
                                     f"no test type `{type_name}` in {TESTS_DIR}; rename or drop the entry"))
            elif function and function not in functions:
                found.append(Finding(WORKFLOW.relative_to(ROOT).as_posix(), offset, "on-screen-test",
                                     f"no test function `{function}` in {TESTS_DIR}; rename or drop the entry"))
    return found


def size_findings(sources: list[Source]) -> list[Finding]:
    found = []
    decls = [d for src in sources for d in declarations(src.path, src.code)]
    by_key: dict[str, list[Decl]] = {}
    for d in decls:
        by_key.setdefault(d.key, []).append(d)
    for key, parts in sorted(by_key.items()):
        main = next((d for d in parts if d.kind != "extension"), None)
        if main is None:
            continue
        lines = sum(d.own_lines for d in parts)
        view = any(re.fullmatch(r"(SwiftUI\.)?View", i) for d in parts for i in d.inherits)
        limit = VIEW_LINES if view else TYPE_LINES
        if lines > limit:
            what = "view" if view else main.kind
            found.append(Finding(main.path, main.start, "type-size",
                                 f"{what} `{key}` is {lines} lines with its extensions, over {limit}; split it by "
                                 "responsibility (swift/TigerDuck/AGENTS.md, Size)"))
        if main.kind in ("class", "actor") and main.stored > STORED_PROPERTIES:
            found.append(Finding(main.path, main.start, "stored-properties",
                                 f"{main.kind} `{key}` holds {main.stored} stored properties, over "
                                 f"{STORED_PROPERTIES}; move a group into a type of its own"))
    for src in sources:
        count = len(src.text.splitlines())
        if count > FILE_LINES:
            found.append(Finding(src.path, 1, "file-size", f"{count} lines, over {FILE_LINES}; split the file"))
    return found


def layering_findings(sources: list[Source]) -> list[Finding]:
    owners: dict[str, str] = {}
    for src in sources:
        layer = next((l for l in LAYERS if src.path.startswith(APP + l)), None)
        if layer:
            for d in declarations(src.path, src.code):
                if d.parent is None and d.kind != "extension":
                    owners[d.key] = layer
    if not owners:
        return []
    pattern = re.compile(r"\b(" + "|".join(sorted(map(re.escape, owners), key=len, reverse=True)) + r")\b")
    found = []
    for src in sources:
        if not src.path.startswith(APP + "Features/"):
            continue
        seen = set()
        for m in pattern.finditer(src.code):
            name = m.group(1)
            if name in seen:
                continue
            seen.add(name)
            found.append(Finding(src.path, line_of(src.code, m.start()), "feature-layering",
                                 f"uses `{name}` from {owners[name]}; go through a store or `AccountSession`"))
    return found


def findings(root: Path = ROOT) -> list[Finding]:
    paths = scope_paths(root)
    sources = load(root, paths)
    workflow = (root / WORKFLOW.relative_to(ROOT)).read_text(encoding="utf-8")
    return (pattern_findings(sources) + base_name_findings(paths) + on_screen_findings(workflow, test_code(root))
            + size_findings(sources) + layering_findings(sources))


def enforced(found: list[Finding]) -> list[Finding]:
    return [f for f in found if RULES[f.rule].phase <= ENFORCED_PHASE]


def main(argv: list[str]) -> int:
    report = "--report" in argv
    found = findings()
    failing = enforced(found)
    later = Counter(f.rule for f in found if RULES[f.rule].phase > ENFORCED_PHASE)
    for f in sorted(found if report else failing, key=lambda f: (RULES[f.rule].phase, f.rule, f.path, f.line)):
        print(f)
    print(f"phase {ENFORCED_PHASE} enforced: {len(failing)} findings")
    for rule in sorted(later, key=lambda r: (RULES[r].phase, r)):
        print(f"  phase {RULES[rule].phase} {rule}: {later[rule]} (not enforced yet)")
    return 1 if failing else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
