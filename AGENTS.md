# TigerDuck

Apple clients for TigerDuck, an NTUST campus assistant: the iOS app with a native macOS build,
the Apple Watch app, and widget and Live Activity extensions, all in `swift/`. `api-poc/` holds
Python probes for NTUST and Moodle endpoints. The push and sync backend is the separate
`tigerduck-app/tigerduck-backend` repository, reached at `https://api.tigerduck.app/v4/*`.

`swift/TigerDuck/`, `swift/TigerDuck/School/`, `swift/TigerDuck/Backend/`, `swift/TigerDuck/Mail/`,
`swift/TigerDuck/Migrations/`, `swift/TigerDuck/Devices/LiveActivity/` and `api-poc/api/` have their
own AGENTS.md. Read it before editing files in that directory.

## Agent files

- AGENTS.md files are the only rule files. Do not add a `CLAUDE.md`, `.claude/CLAUDE.md` or
  `CLAUDE.local.md`: with one present, Claude Code skips every AGENTS.md. Claude Code reads
  AGENTS.md from v2.1.277.
- Hand-written skills live in `.agents/skills/<name>/`, with a relative symlink to each in
  `.claude/skills/`. OpenSpec writes its own `openspec-*` copies into both folders.

## Setup

```bash
git submodule update --init --recursive      # before the first build
npm install -g @fission-ai/openspec@1.14.1   # the version the committed OpenSpec skills match
export OPENSPEC_TELEMETRY=0                  # put in your shell profile; opts out of usage statistics
brew install xcode-build-server
(cd swift && xcode-build-server config -project TigerDuck.xcodeproj -scheme TigerDuck)
```

The last line writes the gitignored `swift/buildServer.json`, without which `swift-lsp` reports
false errors. After upgrading OpenSpec, run `openspec update` and commit the regenerated skills
with the new version in the install line.

## Commands

```bash
xcodebuild test -project swift/TigerDuck.xcodeproj -scheme TigerDuck -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:TigerDuckTests
xcodebuild test -project swift/TigerDuck.xcodeproj -scheme 'TigerDuckWatch Watch App' -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm),OS=26.5'
xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuck -destination 'platform=macOS'
(cd swift/Packages/SwiftMail && swift test)
(cd swift/Packages/TigerDuckCore && swift test)
python3 tools/check_architecture.py
python3 tools/check_account_state.py
python3 tools/check_comments.py check --base origin/dev
python3 tools/check_macos_sources.py
python3 tools/check_privacy_manifests.py
python3 tools/localization/check_keys.py
python3 tools/generate_licenses.py --check
python3 -m unittest discover -s tools -p 'test_*.py'
```

Without `OS=`, xcodebuild picks the newest installed runtime, which may not have that device
(`xcrun simctl list devices available`). Run one `xcodebuild` at a time; two at once compete for
the same build folder.

## Conventions

- One-time upgrade compatibility code goes only in `swift/TigerDuck/Migrations/`.
- Label issues and pull requests as `docs/issue-triage.md` says.
- Localized strings come from the `app-translation` submodule, which takes its own pull requests.
  Each Apple target's build generates its `.lproj` bundles, so `swift/` holds no `*.lproj` folder
  or `.strings` file. What's New feature pages are the exception: their zh-Hant and English copy
  is written in Swift, in `swift/TigerDuck/Features/Updates/` (`WhatsNewCatalog.swift` and its
  page files).
- A function, property or table that hands out a localization key returns or holds a
  `LocalizedStringResource`; `tools/localization/check_keys.py` does not read a key held in a
  plain `String`.
- The app and Watch app targets, unlike the others, default to `@MainActor`
  (`SWIFT_DEFAULT_ACTOR_ISOLATION`). Mark a type used off the main actor there `nonisolated`, or
  its synthesized conformances are main-actor isolated.
- After adding, moving or deleting an app-target Swift file, run
  `python3 tools/check_macos_sources.py --write`, listing the file in
  `tools/macos-excluded-sources.txt` first if macOS must not compile it. The script owns the
  `INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]` arrays in `project.pbxproj`.

## Comments

`tools/check_comments.py` checks the language, citations and length of Swift comments in CI and,
in Claude Code, after every edit (`.claude/hooks/check-comments.sh`). Review applies the rest:

- Comment only what the code cannot say: a behavior of Apple's platforms, the school's servers,
  a dependency or a protocol we cannot change, a contract callers rely on, a license, or an
  issue or RFC link. Write the reason; git keeps the history and who decided.
- When our own code needs a comment to be understood, such as its ordering, a flag or a guard,
  add the missing name, type or state instead.
- Cite only what a reader can open: repository paths, RFC sections, Apple documentation, issue
  and pull request URLs.
- Use plain wording: no bold, no `IMPORTANT:` or `NOTE:`, no em dashes, and no "exactly",
  "deliberately", "intentionally" or "note that" as emphasis.
- Longer knowledge goes where it belongs: rationale that spans files in an ADR under
  `docs/decisions/`, procedures in a skill, agent rules in the nearest AGENTS.md, and described
  behavior in a test.

## Planning

- Use an OpenSpec change (the `openspec-propose` skill, `/opsx:propose` in Claude Code) only for
  work that spans sessions, changes the architecture or needs both maintainers to agree. Plan
  smaller work in plan mode or with `/feature-dev`.
- Archive a change with `openspec archive <name>` after its last pull request merges.
- Write plans and specs only to tracked paths.

## Gotchas

- The Watch complication target, `TigerDuckWatchWidgetExtension`, compiles only the files of
  `swift/Shared/`, the Watch app and the app folder that its membership exceptions in
  `project.pbxproj` list, so a file they come to need joins that list. The Watch app also
  compiles the complication's entry, provider and views, for `TigerDuckWatch Watch AppTests`.
- `swift/Packages/SwiftMail/` is vendored; read its `VENDORED.md` before changing it.
