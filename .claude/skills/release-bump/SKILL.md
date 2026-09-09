---
name: release-bump
description: Use when bumping TigerDuck's marketing version (vX.Y.Z) — bumps project.pbxproj, adds the in-app whatsnew.json entry, refreshes README.md + README.en.md (badge + version-history row), and creates a single chore(release) commit. Trigger on phrases like "bump version", "升版", "release X.Y.Z", "更新 README 標版本", or whenever pbxproj's MARKETING_VERSION changes are staged.
---

# TigerDuck Release Bump

End-to-end checklist for cutting a new TigerDuck App Store release. The whole loop should be one commit. Optimized for fast iteration — minimal questions, surgical edits.

## When to invoke

- User says "bump version to X.Y.Z" / "升版到 X.Y.Z" / "release X.Y.Z"
- User says "新版本送出" / "版本送出了" and asks to update README
- A diff already stages `swift/TigerDuck.xcodeproj/project.pbxproj` with a `MARKETING_VERSION` change
- User says "幫我 commit" and the diff is exactly a version bump

## Inputs

Gather from the user only if not already obvious:

1. **Target version** `X.Y.Z` — auto-detect if pbxproj is already staged (read the `+` lines)
2. **Highlights for the version-history row** — auto-extract from `git log <prev-tag>..HEAD` if the user hasn't dictated them; confirm the framing in 1 short line before editing READMEs

## Procedure

### 1. Audit current state

```bash
git status
git tag --sort=-creatordate | head -3                           # latest 3 tags
git log --oneline "$(git describe --tags --abbrev=0)"..HEAD     # commits since last tag
grep -n "MARKETING_VERSION" swift/TigerDuck.xcodeproj/project.pbxproj
```

The pbxproj has **16** `MARKETING_VERSION` lines: **8 are real shipping
targets** (Debug + Release each for TigerDuck, TigerDuckLiveActivity,
`watchkitapp` and Widgets) and **8 are `= 1.0;` placeholders** (the four test
/ UITest targets). **Only bump the 8 shipping lines** — leave `1.0` alone.

Confirm the split rather than trusting this count; targets get added:

```bash
grep -oE 'MARKETING_VERSION = [^;]*;' swift/TigerDuck.xcodeproj/project.pbxproj | sort | uniq -c
```

Every shipping line must move together. Apple rejects a build whose embedded
extensions or watch app disagree with the host app on `CFBundleShortVersionString`.

### 2. Bump pbxproj (skip if already staged)

Use Edit with `replace_all: true` to flip every `MARKETING_VERSION = <PREV>;` → `MARKETING_VERSION = <NEW>;`. The `= 1.0;` placeholders are untouched because they don't match `<PREV>`.

```text
old_string: MARKETING_VERSION = 1.6.0;
new_string: MARKETING_VERSION = 1.6.1;
replace_all: true
```

Verify after edit: `grep -c "MARKETING_VERSION = <NEW>;" swift/TigerDuck.xcodeproj/project.pbxproj` should return **8**.

### 3. Synthesize highlights

Read `git log <prev-tag>..HEAD --oneline` and group commits. Pick 2–4 user/product-meaningful items, **skip pure refactors and internal cleanups**. Phrase as one comma-separated line with a leading theme emoji.

**Theme emoji conventions** (be consistent with existing rows):

| Emoji | Theme |
|:---:|---|
| 🌏 | i18n / locale / RTL |
| 📣 | bulletins / announcements |
| 📊 | scores / GPA / charts |
| 🚀 | backend / infrastructure launch |
| 🤖 | Android / FCM / cross-platform |
| 🎨 | theme / customization |
| 📚 | assignments / Moodle |
| 📋 | class table |
| 🏛️ | library |
| 🔔 | push / Live Activity / notifications |

If the version is a fix-only release (no headline feature), drop the emoji and lead with a plain summary.

### 4. Update README.md (繁中) + README.en.md (English) in lockstep

Both files always change together. Two surgical edits per file:

**A. Version badge** (around line 7):

```text
old: [![Version](https://img.shields.io/badge/Version-v<PREV>-00BB00?style=for-the-badge)](https://github.com/tigerduck-app/tigerduck-app/releases/tag/v<PREV>)
new: [![Version](https://img.shields.io/badge/Version-v<NEW>-00BB00?style=for-the-badge)](https://github.com/tigerduck-app/tigerduck-app/releases/tag/v<NEW>)
```

Color is **`00BB00`**. Do not change.

**B. Version history table** — insert a new row right under the header.

`README.md` (Chinese — section `## 版本歷程`):

```markdown
| 版本 | 日期 | 重點 |
|:---:|:---:|---|
| **`v<NEW>`** | YYYY-MM-DD | <emoji> <highlight in zh-Hant> |
| **`v<PREV>`** | ... | (existing row) |
```

`README.en.md` (English — section `## Release History`):

```markdown
| Version | Date | Highlights |
|:---:|:---:|---|
| **`v<NEW>`** | YYYY-MM-DD | <emoji> <highlight in English> |
| **`v<PREV>`** | ... | (existing row) |
```

Date is the bump date in `YYYY-MM-DD` (today, unless user specifies). Always use the literal version cell format **``` **`vX.Y.Z`** ```** — bold + backticks.

If the version unlocks new product capability, also tick the matching item in the **Roadmap / 開發規劃** section and append `` `vX.Y.Z` `` after the description. Don't invent roadmap entries; only check off ones that already exist.

### 5. Add the in-app "What's new" entry

`swift/TigerDuck/whatsnew.json` drives the sheet the app shows on first launch
after an update, and the Settings → About "What's new" row. **A version with no
entry here silently shows nothing** — the decoder is defensive on purpose, so a
missing entry is not an error you will see. Add it every marketing bump.

Top-level keys are `CFBundleShortVersionString` values, in ascending order.
Each needs both locales — `zh-TW` and `en`; the repository falls back to `en`
for every other language, so those two are the whole surface.

```json
  "<NEW>": {
    "zh-TW": {
      "title": "<NEW> 更新內容",
      "highlights": ["...", "..."]
    },
    "en": {
      "title": "What's new in <NEW>",
      "highlights": ["...", "..."]
    }
  }
```

- 3–5 highlights, **user-facing outcomes only** — no internal refactors, no
  bug-fix plumbing the user never saw. This is App Store copy, not a changelog.
- Full sentences ending in `。` / `.`, same voice as the neighbouring entries.
- The zh and en lists are translations of each other: same count, same order.
- Append the block at the end, keep 2-space indent, and re-validate:
  `python3 -c "import json;json.load(open('swift/TigerDuck/whatsnew.json'))"`
- Reuse the README highlights as the source, then trim them to what a user
  would actually notice.

### 6. Commit

Stage exactly the files we touched — never `git add .` (the repo often has untracked `docs/website-spec.md`, dirty `app-translation` submodule pointer, `firebase-debug.log`, etc. that must NOT be in a release commit).

```bash
git add swift/TigerDuck.xcodeproj/project.pbxproj swift/TigerDuck/whatsnew.json README.md README.en.md
```

Commit message — Chinese body, no `Co-Authored-By` (per global preference):

```text
chore(release): bump marketing version to <NEW>

- pbxproj 8 條 shipping MARKETING_VERSION（4 個 target × Debug/Release）從 <PREV> → <NEW>
- whatsnew.json 補上 <NEW> 的中英「新功能」內容
- README 中英版徽章升級到 v<NEW>
- 版本歷程補上 v<NEW> 重點：
  * <bullet 1>
  * <bullet 2>
  * <bullet 3>
```

If the pbxproj was bumped in a separate earlier commit and this commit is README-only, change the title to `docs(README): add v<NEW> to release history` and drop the pbxproj bullet.

After commit:

```bash
git log --oneline -3
git status      # should be clean of release files; submodule/untracked unrelated files allowed
```

## Build-number-only bumps

Sometimes the marketing version stays put and only the build number moves —
typically because a hotfix shipped from `main` and consumed the build number
`dev` was going to use. `CURRENT_PROJECT_VERSION` is a **separate 16-line
set** from `MARKETING_VERSION`, and unlike it there are no placeholders:
all 16, test targets included, move together and always have.

```bash
grep -oE 'CURRENT_PROJECT_VERSION = [^;]*;' swift/TigerDuck.xcodeproj/project.pbxproj | sort | uniq -c
sed -i '' 's|CURRENT_PROJECT_VERSION = <PREV>;|CURRENT_PROJECT_VERSION = <NEW>;|g' swift/TigerDuck.xcodeproj/project.pbxproj
```

Do **not** touch the READMEs for one of these — no marketing version changed,
so the badge and the release-history table stay as they are. Commit on its own
as `chore(release): bump build number to <NEW> for v<MARKETING>`.

Check both branches before picking the number. If `main` shipped a hotfix
while `dev` was in flight, the two can be sitting on the *same* build with
different marketing versions, and App Store Connect will reject the second
upload:

```bash
git show origin/main:swift/TigerDuck.xcodeproj/project.pbxproj | grep -oE '(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = [^;]*;' | sort | uniq -c
```

## Conventions cheat sheet

- **Two READMEs always move together.** Never update one without the other.
- **`whatsnew.json` moves with them.** Every marketing bump gets an entry, both locales.
- **Badge color is `00BB00`** (green). Don't switch palette.
- **Version cell format:** `` **`vX.Y.Z`** ``
- **Date:** `YYYY-MM-DD` in the table.
- **Commit type:** `chore(release):` for version bumps, `docs(README):` for follow-up doc-only fixes.
- **No `Co-Authored-By`** trailer.
- **Body language:** Chinese, bullet list with `-` and nested `*`.
- **Stage explicitly** — never `git add -A` / `git add .` in this skill.
- **Don't include the `app-translation` submodule pointer** in the release commit unless the user explicitly asks. Submodule bumps are their own commit (`chore(app-translation): bump submodule to <sha>`).
- **Don't touch the 4 `MARKETING_VERSION = 1.0;` placeholder lines** in pbxproj — those are the test targets.

## Verification before commit

- [ ] `grep -c "MARKETING_VERSION = <NEW>;" swift/TigerDuck.xcodeproj/project.pbxproj` → exactly **8**
- [ ] `whatsnew.json` has a `<NEW>` key with both `zh-TW` and `en`, and still parses
- [ ] Both READMEs have the new badge URL and link target
- [ ] Both version-history tables have the new row at the **top** (right under the header divider)
- [ ] Date is `YYYY-MM-DD`, version cell is `` **`vX.Y.Z`** ``
- [ ] Commit body is in Chinese, no `Co-Authored-By`
- [ ] `git status` after commit shows only unrelated untracked/dirty files (submodule pointer, ad-hoc docs)

## Anti-patterns

- ❌ Updating only the Chinese README — the English one drifts and stops matching.
- ❌ Shipping a marketing bump with no `whatsnew.json` entry — the update sheet just doesn't appear, and nothing warns you.
- ❌ Pasting the README highlight verbatim into `whatsnew.json` — the README row is a changelog, the JSON is App Store copy.
- ❌ Bumping `MARKETING_VERSION = 1.0;` placeholders — these are test targets, not shippable.
- ❌ Squashing the app-translation submodule bump into the release commit — keep them separate so reverting a release doesn't unwind translations.
- ❌ Inventing roadmap items to mark as done. Only tick rows that already exist.
- ❌ Using `git add .` — too greedy for this repo's working tree.
- ❌ Leaving the badge URL pointing at the old release tag.
