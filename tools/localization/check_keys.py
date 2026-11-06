#!/usr/bin/env python3
"""Fail when Swift references a localization key the translation repo lacks.

`String(localized: "x")` returns `"x"` verbatim when the key is missing, so an
app that has drifted from `app-translation/` still compiles, still archives, and
still uploads; the raw key only surfaces on a device. TestFlight builds 89-91
shipped that way. This check turns the drift into a build failure.

Run it locally with no arguments; it exits nonzero and lists `file:line` for
every offending reference. Test targets are skipped.

What it reads:
- literals in the key argument of String(localized:), LocalizedStringKey(,
  NSLocalizedString(, String.LocalizationValue( and LocalizedStringResource(;
- snake_case literals in SwiftUI LocalizedStringKey positions (Text, Label,
  Button, .navigationTitle, ...);
- literals passed to a parameter, or to the memberwise label of a stored
  property, typed LocalizedStringResource, String.LocalizationValue or
  LocalizedStringKey (the key types);
- literals a function or computed property of a key type returns: after
  `return`, as a switch case's or an if branch's value, or as the whole body;
- literals in the initial value of a property of a key type, of an array or
  dictionary of one, or of an array of tuples with a field of one, such as
  [(nameKey: LocalizedStringResource, hex: Int)].
A literal counts when it is the whole argument or value, or a whole branch of
a ternary.

What it cannot see:
- a key built at run time (concatenation, interpolation, String(format:));
- a key held in a plain String; hold it as a LocalizedStringResource instead;
- an array or dictionary of keys that a function or computed property returns;
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
STATIC_MODIFIER = re.compile(r"\b(?:static|class)\b")
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
    t = re.sub(r"@\w+|\s", "", type_text).rstrip("?!")
    if t in LSK_TYPES:
        return "lsk"
    return "value" if t in VALUE_TYPES else None


def top_level(text: str, a: int, b: int, char: str) -> int:
    """Index of the first `char` in text[a:b] outside brackets, or -1."""
    depth = 0
    for i in range(a, b):
        c = text[i]
        if c == char and depth == 0:
            return i
        depth += (c in "([{") - (c in ")]}")
    return -1


def type_shape(type_text: str):
    """How a declared type holds keys: a kind of key_type, ("array" | "dict", shape) or
    ("tuple", [shape or None per field]); None when it holds no key."""
    t = re.sub(r"@\w+|\s", "", type_text).rstrip("?!")
    kind = key_type(t)
    if kind or not t or t[0] not in "[(" or close_of(t, 0) != len(t) - 1:
        return kind
    if t[0] == "[":
        colon = top_level(t, 1, len(t) - 1, ":")
        form, inner = ("dict", t[colon + 1 : -1]) if colon > 0 else ("array", t[1:-1])
        shape = type_shape(inner)
        return (form, shape) if shape else None
    fields = [type_shape(t[label_of(t, a, b)[1] : b]) for a, b in split_args(t, 1, len(t) - 1)]
    return ("tuple", fields) if any(fields) else None


class Helpers:
    """Parameters and stored properties of a key type, found from declarations."""

    def __init__(self) -> None:
        self.labels: dict[str, str] = {}  # label -> kind, matched in any call
        self.positional: dict[str, dict[int, str]] = {}  # function -> index -> kind
        self.scoped: dict[str, dict[str, str]] = {}  # function -> label -> kind

    def learn(self, text: str) -> None:
        self._functions(text)
        self._properties(text)

    def _functions(self, text: str) -> None:
        for m in re.finditer(rf"\b(?:func\s+({IDENT})|(init))\s*(?:<[^>(]*>)?\s*\(", text):
            name = m.group(1) or "init"
            end = close_of(text, m.end() - 1)
            if end < 0:
                continue
            for index, (a, b) in enumerate(split_args(text, m.end(), end)):
                self._param(name, index, text[a:b])

    def _param(self, func: str, index: int, param: str) -> None:
        head, _, tail = param.partition(":")
        names = head.split()
        kind = key_type(tail.split("=")[0])
        if not names or not kind:
            return
        external = names[0]
        if external == "_":
            self.positional.setdefault(func, {})[index] = kind
        elif func == "init":
            self.labels[external] = kind
        else:
            self.scoped.setdefault(func, {})[external] = kind

    def _properties(self, text: str) -> None:
        for m in re.finditer(rf"\b(?:let|var)\s+({IDENT})\s*:\s*([\w.?]+)", text):
            kind = key_type(m.group(2))
            modifiers = max(text.rfind(c, 0, m.start()) for c in "\n;{}") + 1
            # A type's own property, such as an App Intent's `static let title`, is no initialiser's label.
            if kind and not STATIC_MODIFIER.search(text, modifiers, m.start()):
                self.labels[m.group(1)] = kind


def accepts(kind: str, value: str) -> bool:
    """Whether a literal counts as a key for this kind of position."""
    if kind in ("key", "value"):
        return bool(KEY_CHARS.fullmatch(value))
    return bool(SNAKE_CASE.fullmatch(value))  # lsk and SwiftUI positions


# What may come right before a literal that a body returns: `return`, a block's `{`, a case
# label's or a ternary's `:`, a ternary's `?`, or a `;`. What follows it is the first character
# after spaces on its line.
BEFORE_RESULT = re.compile(r"(?:\breturn|[{?:;])\s*\Z")
AFTER_RESULT = re.compile(r"[ \t]*(.?)", re.S)
OPENING = re.compile(r"\s*([\[(])")
DECLARATION = re.compile(rf"\b(?:(?:let|var)\s+{IDENT}\s*:|func\s+{IDENT}\s*(?:<[^>(]*>)?\s*\()")
RETURN_ARROW = re.compile(r"[\s\w()]*?->")


class FileScan:
    def __init__(self, path: Path, src: str) -> None:
        self.path = path
        self.src = src
        self.text, self.lits = mask(src)
        self.lit_at = {s: (e, v, i) for s, e, v, i in self.lits}
        self.line_starts = [0] + [m.end() for m in re.finditer("\n", src)]

    def line(self, offset: int) -> int:
        return bisect.bisect_right(self.line_starts, offset)

    def _literals(self, a: int, b: int, counts, opens: str = "([{"):
        """Plain literals of text[a:b] outside the brackets in `opens` that `counts(start, end)`
        accepts."""
        closes = opens.translate(str.maketrans("([{", ")]}"))
        found, depth, i = [], 0, a
        while i < b:
            if i in self.lit_at:
                end, value, interpolated = self.lit_at[i]
                if not depth and not interpolated and counts(i, end):
                    found.append((i, value))
                i = end
                continue
            depth += (self.text[i] in opens) - (self.text[i] in closes)
            i += 1
        return found

    def arg_literals(self, a: int, b: int) -> list[tuple[int, str]]:
        """Literals that are a whole argument, or a whole branch of a top-level ternary in it."""

        def alone(start: int, end: int) -> bool:
            before = self.text[a:start].rstrip()[-1:]
            after = self.text[end:b].lstrip()[:1]
            return before in ("", "?", ":") and after in ("", ":")

        return self._literals(a, b, alone)

    def result_literals(self, a: int, b: int) -> list[tuple[int, str]]:
        """Literals the body text[a:b] returns, braces of nested blocks included."""

        def result(start: int, end: int) -> bool:
            after = AFTER_RESULT.match(self.text, end, b + 1).group(1)
            return bool(BEFORE_RESULT.search(self.text, a - 1, start)) and after in ("", "\n", "}", ":", ";")

        return self._literals(a, b, result, "([")

    def _type_end(self, i: int) -> int:
        """End of the type that starts at i: the `=`, `{`, newline or separator after it."""
        depth = 0
        while i < len(self.text):
            c = self.text[i]
            if depth == 0 and c in "={\n,;)}":
                return i
            depth += (c in "([") - (c in ")]")
            i += 1
        return i

    def _expression_end(self, i: int) -> int:
        """End of the expression that starts after the whitespace at i."""
        while i < len(self.text) and self.text[i].isspace():
            i += 1
        depth = 0
        while i < len(self.text):
            c = self.text[i]
            if depth == 0 and c in "\n;,)]}":
                return i
            depth += (c in "([{") - (c in ")]}")
            i += 1
        return i

    def value_literals(self, shape, a: int, b: int):
        """(start, value, kind) of the keys an expression of this shape holds."""
        if isinstance(shape, str):
            yield from ((pos, value, shape) for pos, value in self.arg_literals(a, b))
            return
        form, inner = shape
        m = OPENING.match(self.text, a, b)
        if not m or m.group(1) != ("(" if form == "tuple" else "["):
            return
        close = close_of(self.text, m.start(1))
        if not a < close < b:
            return
        for index, (x, y) in enumerate(split_args(self.text, m.end(), close)):
            if form == "array":
                yield from self.value_literals(inner, x, y)
            elif form == "dict":
                colon = top_level(self.text, x, y, ":")
                if colon >= 0:
                    yield from self.value_literals(inner, colon + 1, y)
            elif index < len(inner) and inner[index]:
                yield from self.value_literals(inner[index], label_of(self.text, x, y)[1], y)

    def holder_literals(self):
        """(start, value, kind) of the keys that declarations of a key type return or start with."""
        text = self.text
        for m in DECLARATION.finditer(text):
            start = m.end()
            if text[start - 1] == "(":
                close = close_of(text, start - 1)
                arrow = RETURN_ARROW.match(text, close + 1) if close > 0 else None
                if not arrow:
                    continue
                start = arrow.end()
            end = self._type_end(start)
            shape = type_shape(text[start:end])
            if not shape or end >= len(text):
                continue
            if text[end] == "{" and isinstance(shape, str):
                body_end = close_of(text, end)
                if body_end > 0:
                    yield from ((pos, value, shape) for pos, value in self.result_literals(end + 1, body_end))
            elif text[end] == "=":
                yield from self.value_literals(shape, end + 1, self._expression_end(end + 1))

    def calls(self):
        """Yield (full name, args span list) for every call in the file."""
        pattern = rf"((?:{IDENT}\s*\.\s*)*{IDENT})\s*\("
        for m in re.finditer(pattern, self.text):
            end = close_of(self.text, m.end() - 1)
            if end > 0:
                yield re.sub(r"\s", "", m.group(1)), split_args(self.text, m.end(), end)

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
                    yield from read(start, b, helpers.labels[label])
                elif label and label in helpers.scoped.get(short, {}):
                    yield from read(start, b, helpers.scoped[short][label])
                elif label is None and index in helpers.positional.get(short, {}):
                    yield from read(start, b, helpers.positional[short][index])
        for pos, value, kind in self.holder_literals():
            if accepts(kind, value):
                yield value, self.line(pos)


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
