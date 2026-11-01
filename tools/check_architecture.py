#!/usr/bin/env python3
"""Fail when a shared rule is written again outside its home, or a type outgrows its budget.

Each rule names the phase of the v4 refactor that turns it on. Rules of a phase at or below
ENFORCED_PHASE fail the run; the others are counted, so the work left stays visible without
failing anything yet (docs/decisions/0028-v4-layout.md). Every finding prints as
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
# Sources of the other shipping targets; only the Taipei rule applies to them.
OTHER_TARGET_FOLDERS = EXTENSION_FOLDERS + ("swift/TigerDuckWatch Watch App/", "swift/Shared/")

ENFORCED_PHASE = 8

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
    Rule("academic-term", 1),
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
    Rule("sign-in-read", 8),
    Rule("sign-in-compare", 8),
    Rule("sign-in-in-setter", 8),
    Rule("sign-in-in-cleanup", 8),
    Rule("account-store-write", 8),
    Rule("unbound-backend-auth", 8),
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
    ("unbound-backend-auth", r"\.unbound\s*[({]", (APP + "Backend/Client/", APP + "Backend/CourseCatalog/"),
     "a backend header that names no sign-in outside Backend/Client/ and Backend/CourseCatalog/; a client of "
     "account data takes `AuthTokenManager.backendAuth`"),
)
# Where account work starts and so may read the sign-in it runs for; every other layer is handed
# one (docs/decisions/0029-account-bound-writes.md). The push files build the device's
# registration and the schedule list, each for the sign-in current when it is read.
SIGN_IN_HOMES = tuple(APP + p for p in (
    "Account/", "App/", "Features/", "Platform/", "Debug/", "Devices/", "Backend/Auth/", "Backend/Sync/",
    "Backend/Push/PushDeviceRequests", "Backend/Push/PushRegistrationService.swift",
    "Backend/Push/ScheduleSyncService.swift",
    "Mail/Account/", "Mail/Sync/MailChecker.swift", "School/Library/", "School/Moodle/MoodleTokenService.swift",
    "School/Moodle/MoodleAutologinService.swift", "Migrations/",
))
# Where one sign-in may be compared with another: `SignIn` itself, the backend client and the tokens.
SIGN_IN_COMPARE_HOMES = (APP + "Account/", APP + "Backend/Client/", APP + "Backend/Auth/")
SIGN_IN_READ = re.compile(r"\b(?:currentSignIn|startingSignIn|withSignIn)\b")
# A name ending in `signIn` that is not a flag such as `needsSignIn`.
SIGN_IN_NAME = r"\b(?!(?:is|has|needs|did|should|can|was|will|shows|asks)[A-Z])\w*[sS]ignIn\b"
# `Route.signIn` and `.signIn` name an enum case or a static member, so the sign-in rules skip them.
SIGN_IN_CASE = re.compile(rf"(?:\b[A-Z]\w*|(?<![\w)\]?!]))\.{SIGN_IN_NAME}")
SIGN_IN_PATTERNS = (
    ("sign-in-read", SIGN_IN_READ, SIGN_IN_HOMES,
     "a sign-in read outside the places account work starts; take the `SignIn` the work was started for"),
    ("sign-in-compare", re.compile(
        r"\bSignInSeries\(|\bsignIns\.end\(|\bSet\s*<\s*SignIn\s*>|\[\s*SignIn\s*:|\bDictionary\s*<\s*SignIn\b"
        rf"|{SIGN_IN_NAME}\s*[!=]==?(?!=)(?!\s*(?:\.|nil\b|true\b|false\b))"
        rf"|(?<!\btrue)(?<!\bfalse)\s[!=]==?\s*(?:\w+\.)*{SIGN_IN_NAME}(?![.\w(])"
        rf"|\[[^\[\]]*{SIGN_IN_NAME}[^\[\]]*\]\s*\.(?:contains|firstIndex|lastIndex)\b"
        rf"|\.(?:contains|firstIndex|lastIndex)\(\s*(?:of:\s*)?(?:\w+\.)*{SIGN_IN_NAME}\s*\)"),
        SIGN_IN_COMPARE_HOMES,
     "a sign-in checked by hand; ask the `SignIn` (`isCurrent`) or hold the value in `SignInBound`"),
)
# A property accessor runs whenever it is used, after an await too, so one that reads the
# current sign-in writes for whichever sign-in is current then (docs/decisions/0029-account-bound-writes.md).
ACCESSOR = re.compile(r"\b(?:set|didSet|willSet)\s*(?:\(\s*\w+\s*\))?\s*\{")
# A `defer` clears what its work holds while running; gated on the sign-in it would leave that
# held once the sign-in ends, so it compares the work's own mark instead.
DEFER = re.compile(r"\bdefer\s*\{")
SIGN_IN_CHECK = re.compile(r"\bisCurrent\b")
# The persistence types of an account and the stores that write them (docs/account-state.md).
ACCOUNT_FILES = {
    "CourseFiles": ("Stores/CourseStore.swift",),
    "AssignmentFiles": ("Stores/AssignmentStore.swift",),
    "CalendarEventFiles": ("Stores/AssignmentStore.swift",),
    "CourseColorFiles": ("Stores/CourseColorStore.swift",),
    "BulletinFiles": ("Stores/Bulletins/BulletinFeed.swift",),
    "ScoreReportFiles": ("School/NTUST/NTUSTScoreService.swift",),
    "MoodleFiles": ("Stores/CourseLookup.swift", "Stores/Moodle/"),
}
# Persistence/ defines them, the sign-out deletes them, and a migration runs before any sign-in work.
ACCOUNT_FILE_HOMES = (APP + "Persistence/", APP + "Account/SignOutPlan.swift", APP + "Migrations/")
# School Mail's stored fields change only through `MailPreferences.change(for:_:)`; the shared store
# is typed read-only, so a writable one comes only from a cast, a conformance or a new store.
MAIL_FIELDS_WRITE = re.compile(
    r"\bas\s*[?!]?\s*(?:any\s+)?(?:MailPreferenceFields|MailSettingsStore)\b|\bMailSettingsStore\s*\("
    r"|\b(?:class|struct|actor|extension)\s+\w+[^{]*:[^{]*\bMailPreferenceFields\b")
MAIL_STORE = APP + "Mail/Store/"
INVENTORY = ROOT / "docs" / "account-state.md"
ACCOUNT_KEY_ROW = re.compile(r"^\|\s*defaults\s*\|\s*`(\w+)`\s*\|\s*(?:school|library)\s*\|\s*`([^`]+\.swift)`")
TAIPEI = re.compile(r'"Asia/Taipei"')
# (rule, pattern on code with comments and strings blanked, message) for rules whose only home is
# TigerDuckCore; like the Taipei rule they read every shipping target.
CORE_PATTERNS = (
    ("academic-term", r"\b1911\b", "the ROC year offset outside TigerDuckCore; use `AcademicTerm` in TigerDuckCore"),
)
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

ATTRIBUTES = re.compile(r"^(?:@[\w.]+(?:\([^)]*\))?\s*)+$")


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
    # A SwiftData `@Model` class: its stored properties are the stored schema, not state to group.
    model: bool = False

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
    attributes = ""
    for no, text, before in logical_lines(code):
        while stack and (before < stack[-1][1] or no > stack[-1][0].end):
            stack.pop()
        if ATTRIBUTES.match(text):
            attributes += " " + text
            continue
        mods, attributes = attributes, ""
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
            decl = Decl(key, m.group("kind"), path, no, code.count("\n", 0, i) + 1, inherits, parent,
                        model=bool(re.search(r"@Model\b", mods + " " + m.group("mods"))))
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


def taipei_findings(sources: list[Source]) -> list[Finding]:
    return [Finding(src.path, line_of(src.text, m.start()), "taipei-zone",
                    '"Asia/Taipei" outside TigerDuckCore; use `TaipeiTime` in TigerDuckCore')
            for src in sources if not src.path.startswith(CORE) for m in TAIPEI.finditer(src.text)]


def core_findings(sources: list[Source]) -> list[Finding]:
    return [Finding(src.path, line_of(src.code, m.start()), rule, message)
            for src in sources if not src.path.startswith(CORE)
            for rule, pattern, message in CORE_PATTERNS for m in re.finditer(pattern, src.code)]


def other_target_paths(root: Path, known: list[str]) -> list[str]:
    listed = subprocess.run(["git", "-C", str(root), "ls-files", *(f"{d}*.swift" for d in OTHER_TARGET_FOLDERS)],
                            capture_output=True, text=True, check=True).stdout.split("\n")
    return sorted({p for p in listed if p} - set(known))


def pattern_findings(sources: list[Source]) -> list[Finding]:
    found = taipei_findings(sources)
    for src in sources:
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
        if main.kind in ("class", "actor") and main.stored > STORED_PROPERTIES and not main.model:
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


def block_end(code: str, opening: int) -> int:
    depth = 0
    for i in range(opening, len(code)):
        depth += {"{": 1, "}": -1}.get(code[i], 0)
        if depth == 0:
            return i
    return len(code)


def block_findings(src: Source, opening: re.Pattern[str], inside: re.Pattern[str], rule: str,
                   message: str) -> list[Finding]:
    found = []
    for block in opening.finditer(src.code):
        start = block.end() - 1
        body = src.code[start:block_end(src.code, start)]
        found += [Finding(src.path, line_of(src.code, start + m.start()), rule, message) for m in inside.finditer(body)]
    return found


def setter_findings(src: Source) -> list[Finding]:
    return (block_findings(src, ACCESSOR, SIGN_IN_READ, "sign-in-in-setter",
                           "a setter that reads the current sign-in; make the write a method that takes its `SignIn`")
            + block_findings(src, DEFER, SIGN_IN_CHECK, "sign-in-in-cleanup",
                             "a cleanup gated on the sign-in; clear only the work's own mark, whatever the sign-in"))


def sign_in_findings(sources: list[Source]) -> list[Finding]:
    found = []
    for src in sources:
        if not src.path.startswith(APP):
            continue
        found += setter_findings(src)
        code = SIGN_IN_CASE.sub(lambda m: " " * len(m.group()), src.code)
        for rule, pattern, homes, message in SIGN_IN_PATTERNS:
            if src.path.startswith(homes):
                continue
            found += [Finding(src.path, line_of(code, m.start()), rule, message) for m in pattern.finditer(code)]
    return found


def account_keys(inventory: str) -> dict[str, str]:
    """Each account-scoped `Defaults` key and the file that clears it, which is its one writer."""
    return {m.group(1): m.group(2) for line in inventory.split("\n") if (m := ACCOUNT_KEY_ROW.match(line))}


def key_write(key: str) -> re.Pattern[str]:
    """A write of an account key, which names its sign-in, or the sign-out's reset of it; a write
    without a sign-in does not compile (`Account/AccountKey.swift`)."""
    name = rf"(?:AccountKeys)?\.{key}\b"
    return re.compile(rf"Defaults\[\s*{name}\s*,\s*for:|Defaults\.reset\([^)]*\.{key}\b")


def account_store_findings(sources: list[Source], inventory: str) -> list[Finding]:
    files = re.compile(r"\b(" + "|".join(ACCOUNT_FILES) + r")\b")
    keys = {key: (path, key_write(key)) for key, path in account_keys(inventory).items()}
    found = []
    for src in sources:
        if not src.path.startswith(APP) or src.path.startswith(ACCOUNT_FILE_HOMES):
            continue
        if not src.path.startswith(MAIL_STORE):
            found += [Finding(src.path, line_of(src.code, m.start()), "account-store-write",
                              "School Mail's fields written outside Mail/Store/; use `MailPreferences.change(for:_:)`")
                      for m in MAIL_FIELDS_WRITE.finditer(src.code)]
        for m in files.finditer(src.code):
            stores = ACCOUNT_FILES[m.group(1)]
            if not src.path.startswith(tuple(APP + s for s in stores)):
                found.append(Finding(src.path, line_of(src.code, m.start()), "account-store-write",
                                     f"`{m.group(1)}` outside its store; read and write through {', '.join(stores)}"))
        for key, (home, write) in keys.items():
            if src.path == home:
                continue
            found += [Finding(src.path, line_of(src.code, m.start()), "account-store-write",
                              f"`{key}` written outside {home}; write it through that store")
                      for m in write.finditer(src.code)]
    return found


def findings(root: Path = ROOT) -> list[Finding]:
    paths = scope_paths(root)
    sources = load(root, paths)
    others = load(root, other_target_paths(root, paths))
    workflow = (root / WORKFLOW.relative_to(ROOT)).read_text(encoding="utf-8")
    return (pattern_findings(sources) + taipei_findings(others) + core_findings(sources + others)
            + base_name_findings(paths) + on_screen_findings(workflow, test_code(root))
            + size_findings(sources) + layering_findings(sources) + sign_in_findings(sources)
            + account_store_findings(sources, (root / INVENTORY.relative_to(ROOT)).read_text(encoding="utf-8")))


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
