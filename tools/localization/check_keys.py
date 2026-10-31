#!/usr/bin/env python3
"""Fail when Swift references a localization key the translation repo lacks.

`String(localized: "x")` returns `"x"` verbatim when the key is missing, so an
app that has drifted from `app-translation/` still compiles, still archives, and
still uploads; the raw key only surfaces on a device. TestFlight builds 89-91
shipped that way. This check turns the drift into a build failure.

Run it locally with no arguments; it exits nonzero and lists `file:line` for
every offending reference. Test targets are skipped.

What it reads: string literals in the key argument of String(localized:),
LocalizedStringKey(, NSLocalizedString(, String.LocalizationValue( and
LocalizedStringResource( (a ternary included); snake_case literals in SwiftUI
LocalizedStringKey positions (Text, Label, Button, .navigationTitle, ...); and
literals passed to helpers found from their declarations (a parameter or stored
property typed LocalizedStringKey, LocalizedStringResource or
String.LocalizationValue, or a String named key or ending in Key), including
tuple tables such as [(nameKey: String, hex: Int)].

What it cannot see:
- a key built at run time (concatenation, interpolation, String(format:));
- a key returned by a function or switch and passed on (weekdayKey(_:));
- a key held in a variable, property or dictionary and not declared as above;
- a helper that takes a key in a closure or generic parameter;
- a SwiftUI view or modifier missing from SWIFTUI_KEY_CALLS;
- display text that happens to be snake_case in a SwiftUI position.
"""

import bisect
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWIFT_DIR = ROOT / "swift"
# Every locale carries an identical key set, so the canonical source is enough. The Apple build
# gets its `shared` and `apple` groups.
REFERENCE = ROOT / "app-translation" / "source" / "en.json"
APPLE_GROUPS = ("shared", "apple")
BASELINE = Path(__file__).with_name("known-missing-keys.txt")

KEY_CHARS = re.compile(r"[A-Za-z0-9_.]+")
SNAKE_CASE = re.compile(r"[a-z0-9]+(?:_[a-z0-9]+)+")
IDENT = r"[A-Za-z_]\w*"
FILLER = "\x01"  # replaces literal text in the masked copy
INTERP = "\x02"  # replaces the \( and ) of an interpolation

# Views and modifiers whose first unlabeled argument is a LocalizedStringKey literal.
SWIFTUI_KEY_CALLS = frozenset(
    "Text Label Button Toggle Section Picker Link Menu NavigationLink TextField SecureField "
    "LabeledContent ContentUnavailableView GroupBox DisclosureGroup DatePicker Stepper "
    "ProgressView ShareLink Tab "
    "navigationTitle navigationBarTitle alert confirmationDialog help accessibilityLabel "
    "accessibilityHint accessibilityValue".split()
)
# Labeled arguments of modifiers that take a LocalizedStringKey.
SWIFTUI_KEY_LABELS = {"searchable": {"prompt"}}
# Initialisers that take the key as their first argument, or as `localized:`.
KEY_INITS = {
    "NSLocalizedString": None,
    "LocalizedStringKey": None,
    "LocalizedStringResource": None,
    "String.LocalizationValue": None,
    "LocalizationValue": None,
    "String": "localized",
}
LSK_TYPES = {"LocalizedStringKey"}
VALUE_TYPES = {"LocalizedStringResource", "String.LocalizationValue", "LocalizationValue"}


def mask(src: str) -> tuple[str, list[tuple[int, int, str, bool]]]:
    """Blank comments, hide literal text and return the literals.

    The masked copy keeps offsets and newlines, so structure can be scanned on it while
    a literal's value comes from the returned (start, end, value, interpolated) list.
    """
    out = list(src)
    lits: list[tuple[int, int, str, bool]] = []

    def blank(a: int, b: int) -> None:
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    def string(i: int) -> int:
        start = i
        hashes = 0
        while src[i] == "#":
            hashes += 1
            i += 1
        multi = src.startswith('"""', i)
        end_delim = ('"""' if multi else '"') + "#" * hashes
        i += 3 if multi else 1
        interp = "\\" + "#" * hashes + "("
        value: list[str] = []
        interpolated = False
        while i < len(src):
            if src.startswith(end_delim, i):
                i += len(end_delim)
                break
            if src.startswith(interp, i):
                interpolated = True
                for k in range(i, i + len(interp)):
                    out[k] = INTERP
                i = code(i + len(interp), True)
                out[i] = INTERP
                i += 1
                continue
            if src[i] == "\\" and hashes == 0:
                value.append(src[i : i + 2])
                out[i] = out[i + 1] = FILLER
                i += 2
                continue
            value.append(src[i])
            if out[i] != "\n":
                out[i] = FILLER
            i += 1
        lits.append((start, i, "".join(value), interpolated))
        return i

    def code(i: int, in_interp: bool) -> int:
        depth = 0
        while i < len(src):
            two = src[i : i + 2]
            c = src[i]
            if two == "//":
                j = src.find("\n", i)
                j = len(src) if j < 0 else j
                blank(i, j)
                i = j
            elif two == "/*":
                j, nest = i + 2, 1
                while j < len(src) and nest:
                    if src.startswith("/*", j):
                        nest, j = nest + 1, j + 2
                    elif src.startswith("*/", j):
                        nest, j = nest - 1, j + 2
                    else:
                        j += 1
                blank(i, j)
                i = j
            elif c == '"' or (c == "#" and re.match(r'#+"', src[i : i + 40])):
                i = string(i)
            elif c == "(":
                depth, i = depth + 1, i + 1
            elif c == ")":
                if in_interp and depth == 0:
                    return i
                depth, i = depth - 1, i + 1
            else:
                i += 1
        return i

    code(0, False)
    return "".join(out), lits


def close_of(text: str, open_at: int) -> int:
    """Index of the bracket closing the one at open_at, or -1."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = []
    for i in range(open_at, len(text)):
        c = text[i]
        if c in pairs:
            stack.append(pairs[c])
        elif c in ")]}":
            if not stack or stack.pop() != c:
                return -1
            if not stack:
                return i
    return -1


def split_args(text: str, a: int, b: int) -> list[tuple[int, int]]:
    """Top-level comma-separated spans of text[a:b]."""
    spans, depth, begin = [], 0, a
    for i in range(a, b):
        c = text[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            spans.append((begin, i))
            begin = i + 1
    if text[begin:b].strip():
        spans.append((begin, b))
    return spans


def label_of(text: str, a: int, b: int) -> tuple[str | None, int]:
    m = re.match(rf"\s*({IDENT})\s*:(?!:)", text[a:b])
    return (m.group(1), a + m.end()) if m else (None, a)


def key_type(type_text: str) -> str | None:
    t = re.sub(r"@\w+|\s", "", type_text).rstrip("?")
    if t in LSK_TYPES:
        return "lsk"
    return "value" if t in VALUE_TYPES else None


def is_key_name(name: str) -> bool:
    return name == "key" or (name.endswith("Key") and not name.startswith("for"))


class Helpers:
    """Key-taking parameters and properties found from declarations."""

    def __init__(self) -> None:
        self.labels: dict[str, str] = {}  # label -> kind, matched in any call
        self.positional: dict[str, dict[int, str]] = {}  # function -> index -> kind
        self.scoped: dict[str, dict[str, str]] = {}  # function -> label -> kind (String keys)
        self.tuples: list[tuple[str, int, str]] = []  # (name, index, field) of tuple tables
        self.string_props: set[str] = set()  # String properties named like a key
        self.localized_members: set[str] = set()  # `.name` seen as a localizing call's key

    def learn(self, text: str) -> None:
        self.localized_members.update(
            re.findall(
                r"(?:LocalizedStringKey|LocalizationValue|LocalizedStringResource|NSLocalizedString"
                r"|localized:)\s*\(?[^()\n]*?\.(\w+)\s*\)",
                text,
            )
        )
        self._functions(text)
        self._properties(text)
        self._tuple_tables(text)

    def _functions(self, text: str) -> None:
        for m in re.finditer(rf"\b(?:func\s+({IDENT})|(init))\s*(?:<[^>(]*>)?\s*\(", text):
            name = m.group(1) or "init"
            end = close_of(text, m.end() - 1)
            if end < 0:
                continue
            body = re.compile(r"\s*(?:->[^{]*)?\{").match(text, end + 1)
            body_end = close_of(text, body.end() - 1) if body else -1
            body_text = text[body.end() : body_end] if body and body_end > 0 else ""
            for index, (a, b) in enumerate(split_args(text, m.end(), end)):
                self._param(name, index, text[a:b], body_text)

    def _param(self, func: str, index: int, param: str, body: str) -> None:
        head, _, tail = param.partition(":")
        names = head.split()
        if not names or not tail.strip():
            return
        external, internal = names[0], names[-1]
        type_text = tail.split("=")[0]
        kind = key_type(type_text)
        if kind:
            if external == "_":
                self.positional.setdefault(func, {})[index] = kind
            elif func == "init":
                self.labels[external] = kind
            else:
                self.scoped.setdefault(func, {})[external] = kind
        elif (
            re.sub(r"\s", "", type_text) == "String"
            and is_key_name(internal)
            and re.search(rf"(?:[Ll]ocaliz\w*|\bstring)\s*\([^)]*\b{internal}\b", body)
        ):
            if external == "_":
                self.positional.setdefault(func, {})[index] = "str"
            elif is_key_name(external):
                self.scoped.setdefault(func, {})[external] = "str"

    def _properties(self, text: str) -> None:
        for m in re.finditer(rf"\b(?:let|var)\s+({IDENT})\s*:\s*([\w.?]+)", text):
            kind = key_type(m.group(2))
            if kind:
                self.labels[m.group(1)] = kind
            elif m.group(2) == "String" and is_key_name(m.group(1)):
                self.string_props.add(m.group(1))

    def finish(self) -> None:
        """Keep String names that some localizing call reads as a member."""
        for name in self.string_props & self.localized_members:
            self.labels.setdefault(name, "str")
        self.tuples = [t for t in self.tuples if t[2] in self.localized_members]

    def _tuple_tables(self, text: str) -> None:
        for m in re.finditer(rf"\b(?:let|var)\s+({IDENT})\s*:\s*\[\(([^)]*)\)\]", text):
            fields = [f.split(":")[0].strip() for f in m.group(2).split(",")]
            for index, field in enumerate(fields):
                if is_key_name(field):
                    self.tuples.append((m.group(1), index, field))


def accepts(kind: str, value: str) -> bool:
    """Whether a literal counts as a key for this kind of position."""
    if kind == "key":
        return bool(KEY_CHARS.fullmatch(value))
    return bool(SNAKE_CASE.fullmatch(value))  # lsk, str and SwiftUI positions


class FileScan:
    def __init__(self, path: Path, src: str) -> None:
        self.path = path
        self.src = src
        self.text, self.lits = mask(src)
        self.lit_at = {s: (e, v, i) for s, e, v, i in self.lits}
        self.nested = self._nested_starts()
        self.line_starts = [0] + [m.end() for m in re.finditer("\n", src)]

    def _nested_starts(self) -> set[int]:
        """Literals that sit inside an interpolation of another literal."""
        inside: set[int] = set()
        for s, e, _, interpolated in self.lits:
            if interpolated:
                inside.update(t for t, *_ in self.lits if s < t < e)
        return inside

    def line(self, offset: int) -> int:
        return bisect.bisect_right(self.line_starts, offset)

    def arg_literals(self, a: int, b: int) -> list[tuple[int, str]]:
        """Plain literals of an argument: outside nested calls, after a top-level `?`."""
        text, found, stack, begin, i = self.text, [], [], a, a
        while i < b:
            c = text[i]
            if i in self.lit_at:
                end, value, interpolated = self.lit_at[i]
                if not stack and i >= begin and not interpolated:
                    found.append((i, value))
                i = end
                continue
            if c == "?" and not stack and begin == a and text[i - 1].isspace():
                begin = i
            elif c in "([{":
                prev = text[a:i].rstrip()[-1:]
                call = c != "(" or (bool(prev) and (prev.isalnum() or prev in "_>])?!"))
                stack.append(call)
            elif c in ")]}" and stack:
                stack.pop()
            i += 1
        return found

    def calls(self):
        """Yield (full name, args span list) for every call in the file."""
        pattern = rf"((?:{IDENT}\s*\.\s*)*{IDENT})\s*\("
        for m in re.finditer(pattern, self.text):
            end = close_of(self.text, m.end() - 1)
            if end > 0:
                yield re.sub(r"\s", "", m.group(1)), split_args(self.text, m.end(), end)

    def tuple_rows(self, name: str, index: int):
        """Literals at one position of every row of `name = [(...), ...]`."""
        for m in re.finditer(rf"\b{re.escape(name)}\b[^=\n]*=\s*\[", self.text):
            end = close_of(self.text, m.end() - 1)
            if end < 0:
                continue
            for a, b in split_args(self.text, m.end(), end):
                if self.text[a:b].lstrip().startswith("("):
                    row = self.text.index("(", a)
                    args = split_args(self.text, row + 1, close_of(self.text, row))
                    if index < len(args):
                        yield args[index]

    def references(self, helpers: Helpers):
        """Yield (key, line) for every localization key literal in the file."""

        def read(a: int, b: int, kind: str):
            for pos, value in self.arg_literals(a, b):
                if accepts(kind, value):
                    yield value, self.line(pos)

        for full, spans in self.calls():
            short = full.rsplit(".", 1)[-1]
            for index, (a, b) in enumerate(spans):
                label, start = label_of(self.text, a, b)
                if full in KEY_INITS or (full == "String" and label == "localized"):
                    wanted = KEY_INITS.get(full)
                    if (wanted is None and index == 0) or label == wanted:
                        yield from read(start, b, "key")
                    continue
                if short in SWIFTUI_KEY_CALLS and index == 0 and label is None:
                    yield from read(start, b, "lsk")
                elif label in SWIFTUI_KEY_LABELS.get(short, ()):
                    yield from read(start, b, "lsk")
                elif label and label in helpers.labels:
                    kind = helpers.labels[label]
                    yield from read(start, b, "key" if kind == "value" else kind)
                elif label and label in helpers.scoped.get(short, {}):
                    kind = helpers.scoped[short][label]
                    yield from read(start, b, "key" if kind == "value" else kind)
                elif label is None and index in helpers.positional.get(short, {}):
                    kind = helpers.positional[short][index]
                    yield from read(start, b, "key" if kind == "value" else kind)
        for name, index, _ in helpers.tuples:
            for a, b in self.tuple_rows(name, index):
                yield from read(a, b, "str")


def shipping_swift_files() -> list[Path]:
    return [
        p
        for p in sorted(SWIFT_DIR.rglob("*.swift"))
        if not any(part.endswith("Tests") or part == ".build" for part in p.relative_to(ROOT).parts)
    ]


def referenced_keys(files: list[Path] | None = None) -> dict[str, list[str]]:
    """key -> ["<path>:<line>", ...] for every reference in the shipping Swift sources."""
    scans = [FileScan(p, p.read_text(encoding="utf-8")) for p in files or shipping_swift_files()]
    helpers = Helpers()
    for scan in scans:
        helpers.learn(scan.text)
    helpers.finish()
    found: dict[str, list[str]] = {}
    for scan in scans:
        rel = scan.path.relative_to(ROOT)
        for key, line in scan.references(helpers):
            site = f"{rel}:{line}"
            if site not in found.setdefault(key, []):
                found[key].append(site)
    return found


def translated_keys() -> set[str]:
    if not REFERENCE.exists():
        sys.exit(
            f"error: {REFERENCE.relative_to(ROOT)} not found. Run "
            "`git submodule update --init --recursive` first."
        )
    source = json.loads(REFERENCE.read_text(encoding="utf-8"))
    return {key for group in APPLE_GROUPS for key in source.get(group, {})}


def baseline_keys() -> set[str]:
    if not BASELINE.exists():
        return set()
    return {
        line.strip()
        for line in BASELINE.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    }


def main() -> int:
    translated = translated_keys()
    referenced = referenced_keys()
    baseline = baseline_keys()

    missing = {k: v for k, v in referenced.items() if k not in translated}
    new = {k: v for k, v in missing.items() if k not in baseline}

    resolved = sorted(baseline - set(missing))
    if resolved:
        print(
            f"note: {len(resolved)} baselined key(s) now translated; drop them "
            f"from {BASELINE.name}: {', '.join(resolved)}"
        )

    if not new:
        print(f"OK {len(referenced)} keys referenced, {len(translated)} translated, "
              f"{len(missing)} baselined")
        return 0

    for key in sorted(new):
        for site in new[key]:
            path, line = site.rsplit(":", 1)
            print(f"::error file={path},line={line}::"
                  f"Localization key '{key}' has no translation in app-translation/. "
                  f"It will render as the raw key.")
    print(f"\nerror: {len(new)} localization key(s) missing from the translation "
          f"repo. Add them to tigerduck-app/app-translation and bump the "
          f"submodule, or fix the key name.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
