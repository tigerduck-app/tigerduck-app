#!/usr/bin/env python3
"""Check for untranslated keys by comparing each language file to English.

A key is considered untranslated if its value is identical to the English
value (and the language is not en or en-GB).  Some keys are expected to
match English (brand names, technical terms) — add them to SKIP_KEYS.
"""

import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SOURCE_DIR = os.path.join(SCRIPT_DIR, "..", "app-translation", "source")

# Keys that are expected to be identical to English in most languages.
SKIP_KEYS = {
    "app_name",
}

# Languages where identical values are expected (English variants).
SKIP_LANGS = {"en-GB"}


def main():
    en_path = os.path.join(SOURCE_DIR, f"en.json")
    with open(en_path, "r", encoding="utf-8") as f:
        en_data = json.load(f)

    lang_files = sorted(
        f for f in os.listdir(SOURCE_DIR)
        if f.endswith(".json") and f not in ("en.json",)
    )

    total_untranslated = 0
    langs_with_issues = 0

    for filename in lang_files:
        lang_code = filename.replace(".json", "")
        if lang_code in SKIP_LANGS:
            continue

        filepath = os.path.join(SOURCE_DIR, filename)
        with open(filepath, "r", encoding="utf-8") as f:
            lang_data = json.load(f)

        untranslated = []
        for section, en_keys in en_data.items():
            if not isinstance(en_keys, dict):
                continue
            lang_section = lang_data.get(section, {})
            for key, en_value in en_keys.items():
                if key in SKIP_KEYS:
                    continue
                lang_value = lang_section.get(key)
                if lang_value is None:
                    untranslated.append((section, key, "MISSING"))
                elif lang_value == en_value:
                    untranslated.append((section, key, "SAME AS EN"))

        if untranslated:
            langs_with_issues += 1
            total_untranslated += len(untranslated)
            print(f"\n{lang_code} ({len(untranslated)} untranslated):")
            for section, key, status in untranslated:
                print(f"  [{section}] {key}: {status}")

    if total_untranslated == 0:
        print("All keys are translated across all languages!")
    else:
        print(f"\n{'='*60}")
        print(f"Total: {total_untranslated} untranslated keys across {langs_with_issues} languages")

    return 1 if total_untranslated > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
