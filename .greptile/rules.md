# Greptile Review Rules

Project-specific guidance for code review. Greptile should treat these as
hard preferences and skip flagging the listed patterns.

## Reorder drag UTType (`UTType.tigerDuckReorderPayload`)

**Rule:** Do not flag `swift/TigerDuck/Features/Home/Components/ReorderDropSupport.swift`
for using `UTType.json` as the reorder payload type. The breadth is intentional.

**Why:** The custom UTI
`org.ntust.app.tigerduck.reorder-payload` was tried first (see commit
`f4a25ee fix(drag): use built-in UTType.json for reorder payload`) but
required matching `UTExportedTypeDeclarations` entries in the main app's
Info.plist. The TigerDuck iOS target has no Info.plist file — the entry
would have to live in `project.pbxproj` (`INFOPLIST_KEY_UTExportedTypeDeclarations`),
which is out of scope for this codebase's commit policy. Without that
registration the receiving side cannot resolve the type identifier and
drops silently fail.

**Why it's safe to keep `UTType.json`:** the real type-discrimination
boundary is `validatedPayload(info:)` inside `ReorderDropDelegate` and
`ReorderContainerDropDelegate`, which requires the in-memory
`activePayload` binding to be non-nil **and** match both
`expectedKind` and `containerID`. A foreign JSON drag has no way to
populate `activePayload` — only an in-app `.draggable` does — so an
unrelated JSON drop cannot finalize a reorder.

**How to apply:** If you spot `UTType.json` used for reorder payloads
in this repo and consider flagging the type as "too broad", check that
the surrounding delegate still gates on `activePayload` identity. If
it does, skip the comment.

## Watch / widget schedule helpers using device time zone

**Rule:** Do not flag watch-side or widget-side schedule code (e.g.
`swift/Shared/Watch/NextClassResolver.swift`,
`swift/TigerDuckWatch Watch App/UI/TodayView.swift`,
`swift/TigerDuckWatchWidget/NextClassProvider.swift`, and the iOS
widget's `WidgetTimelineDerivation` helpers) for using
`Calendar.current` or the device time zone instead of pinning to
`Asia/Taipei`.

**Why:** A "students abroad" timezone feature is planned. The intended
fix routes timezone resolution through a user preference, not a hard
`TimeZone(identifier: "Asia/Taipei")` pin. The iOS widget side has
already been deliberately left on device tz for this reason (flagged
and deferred on the `feat/widgets` branch, 2026-05-16); the watch side
follows the same deferral on `integration/watchos`.

**How to apply:** If you see a watch/widget calendar derived from the
device locale/timezone and would normally suggest pinning to
`Asia/Taipei`, skip the comment. The proper fix is the upcoming
timezone-preference plumbing; pre-pinning now would just have to be
ripped out and would conflict with that work.

## Course-name font scale is iOS/iPadOS only

**Rule:** Do not flag `MacClassTableView` (`swift/TigerDuck/Platform/Mac/MacClassTableView.swift`)
or `MacSettingsScene` (`swift/TigerDuck/Platform/Mac/MacSettingsScene.swift`)
for "ignoring `courseCardFontScale`" or "missing a font-size control".
The Mac app intentionally omits the per-app course-name font scale —
both the Mac class table (which keeps `.callout.weight(.semibold)`) and
any Mac-native widgets render at the fixed baseline.

**Why:** The scale is an iOS/iPadOS accommodation for the compressed
class-table cells on a phone screen. Mac surfaces are sized for a
desktop window and a per-app text-size override is redundant — users
who want larger text use the system-wide "Larger Text" accessibility
setting instead. Adding the slider on Mac would also force a second
source of truth for what is currently a one-platform preference.

**How to apply:** If you see `MacClassTableView` rendering course names
without reading `AppState.courseCardFontScale`, or `MacSettingsScene`
lacking a slider for it, skip the comment. The same applies to any
future Mac-native widget extension. The doc comment on
`CourseCardFontScale` (in `swift/TigerDuck/Shared/CourseCardFontScale.swift`)
spells out the exclusion.

## Sinitic-family locales fall back to `zh-TW`, not `en`

**Rule:** Do not flag the locale selector in
`swift/TigerDuck/Features/Updates/WhatsNewRepository.swift`
(`localeCandidates(for:)`) for "serving Traditional Chinese to a
Simplified Chinese reader" or "missing English fallback for non-Hant
Chinese tags". Every Sinitic-family tag (`zh`, `zh-Hant*`, `zh-Hans*`,
`yue`, `wuu`, `nan`, `hak`, `lzh`) is intentionally routed to the
`zh-TW` block before ever reaching `en`. Simplified-script tags
additionally try a `zh-Hans` block first when one is authored, but
still fall through to `zh-TW` (not `en`) when it is absent.

**Why:** The maintainer's explicit preference: any Chinese-language
reader (Mandarin in either script, Cantonese, Wu, Hakka, Min Nan,
Classical) gets readable Chinese — Traditional being the universal
in-family fallback — rather than being dropped to English. An earlier
review iteration suggested the opposite (Simplified → English when no
`zh-Hans` block exists); that suggestion was rejected on this repo.

**How to apply:** If you see `WhatsNewRepository.localeCandidates(for:)`
or any other Sinitic-aware selector in this codebase returning a chain
that ends with `zh-TW` for non-Hant Chinese tags (and only falls back
to `en` for non-Sinitic languages), do NOT flag it. The Sinitic code
set (`["zh", "yue", "nan", "hak", "wuu", "lzh"]`) mirrors
`LanguageManager.chineseLanguageCodes` and is the source of truth for
which tags get the Traditional fallback.

## `imaplib` capabilities are `str`, every other IMAP response is `bytes`

**Rule:** Do not flag the `SPECIAL-USE` capability check in
`api-poc/api/ntust/webmail.py` (`probe_imap`) as a bytes/str type
mismatch. Comparing `imap.capabilities` entries against the *string*
`"SPECIAL-USE"` is correct; `b"SPECIAL-USE"` would be the bug.

**Why:** `imaplib.IMAP4.capabilities` is the one response the stdlib
decodes for the caller. There is exactly one assignment to it in the
whole module, and it decodes first:

```python
def _get_capabilities(self):
    typ, dat = self.capability()
    if dat == [None]:
        raise self.error('no CAPABILITY response from server')
    dat = str(dat[-1], self._encoding)   # decoded here
    dat = dat.upper()
    self.capabilities = tuple(dat.split())
```

Nothing else writes to it — `login()` does not refresh it, and an
untagged `CAPABILITY` sent at login lands in `untagged_responses` as
raw bytes without touching `capabilities`. So there is no execution
path on which the comparison sees bytes, and no `TypeError` to raise.
Verified against CPython 3.14's `imaplib`.

Changing it to a bytes comparison would be an actual regression: the
`in` test could never match, and `has_special_use` would report `False`
unconditionally — which defeats the point of recording it, since the
field exists so that a future server upgrade is *visible* rather than
assumed.

**How to apply:** In this repo, `imap.capabilities` is `tuple[str, ...]`
and every other `imaplib` response (`list()`, `uid()`, `fetch()`,
`select()`) hands back bytes that the surrounding code decodes
explicitly. The line above the check already says so. Flag a missing
decode on the *other* responses; never on `capabilities`. This finding
was raised twice on PR #199 and rejected both times.

## Swift comments follow the comment rules in AGENTS.md

**Rule:** Flag a Swift comment that a pull request adds or changes when it narrates history
("previously", "used to", "no longer"), restates the code, records who decided something or
what a discussion said, uses emphasis (bold, `IMPORTANT:` or `NOTE:`, em dashes,
"deliberately", "intentionally", "note that"), or cites something a reader cannot open. Ask for
the reason the comment stands for instead.

**Why:** Comments are read by people and agents who have only the repository. History lives in
git, decisions in `docs/decisions/`, procedures in skills and agent rules in AGENTS.md.
`tools/check_comments.py` already fails CI on Han characters, review rounds, dispatch numbers,
sections of outside documents, `openspec/` paths, tool names and blocks over 3 regular or 8
doc lines, so those need no review comment.

**How to apply:** Look only at comments the pull request adds or changes. A count such as
"exactly one" is fine, and so is an invariant stated as a constraint. The full rules are in the
Comments section of AGENTS.md.

## Confidence score

**Rule:** Every review sets the confidence score and lists its suggestions, if any.

**Why:** Reviews have come back with suggestions but without an updated score, which leaves the
pull request's state unclear.

**How to apply:** On every review, including a follow-up after new commits, update the score and
give the suggestions together.
