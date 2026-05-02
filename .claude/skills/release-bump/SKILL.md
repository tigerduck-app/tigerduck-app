---
name: release-bump
description: Use when bumping TigerDuck's marketing version (vX.Y.Z) — bumps project.pbxproj, refreshes README.md + README_en.md (badge + version-history row), and creates a single chore(release) commit. Trigger on phrases like "bump version", "升版", "release X.Y.Z", "更新 README 標版本", or whenever pbxproj's MARKETING_VERSION changes are staged.
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

The pbxproj has **8** `MARKETING_VERSION` lines: **4 are the real shipping targets** (TigerDuck Debug/Release + TigerDuckLiveActivityExtension Debug/Release), and **4 are `= 1.0;` placeholders** (Tests / UITests). **Only bump the 4 shipping lines** — leave `1.0` placeholders alone.

### 2. Bump pbxproj (skip if already staged)

Use Edit with `replace_all: true` to flip every `MARKETING_VERSION = <PREV>;` → `MARKETING_VERSION = <NEW>;`. The `= 1.0;` placeholders are untouched because they don't match `<PREV>`.

```text
old_string: MARKETING_VERSION = 1.6.0;
new_string: MARKETING_VERSION = 1.6.1;
replace_all: true
```

Verify after edit: `grep -c "MARKETING_VERSION = <NEW>;" swift/TigerDuck.xcodeproj/project.pbxproj` should return **4**.

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

### 4. Update README.md (繁中) + README_en.md (English) in lockstep

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

`README_en.md` (English — section `## Release History`):

```markdown
| Version | Date | Highlights |
|:---:|:---:|---|
| **`v<NEW>`** | YYYY-MM-DD | <emoji> <highlight in English> |
| **`v<PREV>`** | ... | (existing row) |
```

Date is the bump date in `YYYY-MM-DD` (today, unless user specifies). Always use the literal version cell format **``` **`vX.Y.Z`** ```** — bold + backticks.

If the version unlocks new product capability, also tick the matching item in the **Roadmap / 開發規劃** section and append `` `vX.Y.Z` `` after the description. Don't invent roadmap entries; only check off ones that already exist.

### 5. Commit

Stage exactly the files we touched — never `git add .` (the repo often has untracked `docs/website-spec.md`, dirty `localization` submodule pointer, `firebase-debug.log`, etc. that must NOT be in a release commit).

```bash
git add swift/TigerDuck.xcodeproj/project.pbxproj README.md README_en.md
```

Commit message — Chinese body, no `Co-Authored-By` (per global preference):

```text
chore(release): bump marketing version to <NEW>

- pbxproj 4 個 shipping target 的 MARKETING_VERSION 從 <PREV> → <NEW>
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

## Conventions cheat sheet

- **Two READMEs always move together.** Never update one without the other.
- **Badge color is `00BB00`** (green). Don't switch palette.
- **Version cell format:** `` **`vX.Y.Z`** ``
- **Date:** `YYYY-MM-DD` in the table.
- **Commit type:** `chore(release):` for version bumps, `docs(README):` for follow-up doc-only fixes.
- **No `Co-Authored-By`** trailer.
- **Body language:** Chinese, bullet list with `-` and nested `*`.
- **Stage explicitly** — never `git add -A` / `git add .` in this skill.
- **Don't include the `localization` submodule pointer** in the release commit unless the user explicitly asks. Submodule bumps are their own commit (`chore(localization): bump submodule to <sha>`).
- **Don't touch the 4 `MARKETING_VERSION = 1.0;` placeholder lines** in pbxproj — those are the test targets.

## Verification before commit

- [ ] `grep -c "MARKETING_VERSION = <NEW>;" swift/TigerDuck.xcodeproj/project.pbxproj` → exactly **4**
- [ ] Both READMEs have the new badge URL and link target
- [ ] Both version-history tables have the new row at the **top** (right under the header divider)
- [ ] Date is `YYYY-MM-DD`, version cell is `` **`vX.Y.Z`** ``
- [ ] Commit body is in Chinese, no `Co-Authored-By`
- [ ] `git status` after commit shows only unrelated untracked/dirty files (submodule pointer, ad-hoc docs)

## Anti-patterns

- ❌ Updating only the Chinese README — the English one drifts and stops matching.
- ❌ Bumping `MARKETING_VERSION = 1.0;` placeholders — these are test targets, not shippable.
- ❌ Squashing the localization submodule bump into the release commit — keep them separate so reverting a release doesn't unwind translations.
- ❌ Inventing roadmap items to mark as done. Only tick rows that already exist.
- ❌ Using `git add .` — too greedy for this repo's working tree.
- ❌ Leaving the badge URL pointing at the old release tag.
