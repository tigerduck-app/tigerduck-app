# TigerDuck

Apple clients for TigerDuck, an NTUST campus assistant: the iOS app with a native macOS build,
the Apple Watch app, and widget and Live Activity extensions, all in `swift/`. `api-poc/` holds
Python probes for NTUST and Moodle endpoints. The push and sync backend is the separate
`tigerduck-app/tigerduck-backend` repository, reached at `https://api.tigerduck.app/v3/*`.

`swift/TigerDuck/`, `swift/TigerDuck/Services/`, `swift/TigerDuck/Services/Migrations/`,
`swift/TigerDuck/LiveActivity/` and `api-poc/api/` have their own AGENTS.md. Read it before
editing files in that directory.

## Agent files

- AGENTS.md files are the only rule files. Do not add a `CLAUDE.md`, `.claude/CLAUDE.md` or
  `CLAUDE.local.md`: when one exists, Claude Code loads only the CLAUDE.md files and skips every
  AGENTS.md, and Codex reads only AGENTS.md. Claude Code reads AGENTS.md from v2.1.277.
- `.claude/settings.json` enables the plugins everyone uses: `swift-lsp`, `feature-dev` and
  `pr-review-toolkit`. Personal plugins go in `.claude/settings.local.json`, which is not
  committed.
- Repository skills live in `.agents/skills/<name>/`, where Codex finds them, and
  `.claude/skills/<name>` is a relative symlink to that folder for Claude Code.

## Setup

```bash
git submodule update --init --recursive      # before the first build
npm install -g @fission-ai/openspec@1.14.1   # the version the committed OpenSpec skills match
export OPENSPEC_TELEMETRY=0                  # put in your shell profile; opts out of usage statistics
brew install xcode-build-server
(cd swift && xcode-build-server config -project TigerDuck.xcodeproj -scheme TigerDuck)
```

The last line writes the gitignored `swift/buildServer.json`; without it `swift-lsp` cannot see
the Xcode project's build settings and reports false errors.

## Commands

```bash
xcodebuild test -project swift/TigerDuck.xcodeproj -scheme TigerDuck -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -only-testing:TigerDuckTests
xcodebuild test -project swift/TigerDuck.xcodeproj -scheme 'TigerDuckWatch Watch App' -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm),OS=26.5'
xcodebuild build -project swift/TigerDuck.xcodeproj -scheme TigerDuck -destination 'platform=macOS'
(cd swift/Packages/SwiftMail && swift test)
python3 tools/check_macos_sources.py
python3 tools/localization/check_keys.py
python3 tools/generate_licenses.py --check
python3 -m unittest discover -s tools -p 'test_*.py'
```

Without `OS=`, xcodebuild picks the newest installed runtime, which may not have that device;
`xcrun simctl list devices available` lists what is installed. Run one `xcodebuild` at a time;
two at once compete for the same build folder.

## Conventions

- One-time upgrade compatibility code goes only in `swift/TigerDuck/Services/Migrations/`.
- Label issues and pull requests as `docs/issue-triage.md` says: an issue gets a type, a pull
  request a kind label.
- `api-poc/` uses `uv` (`api-poc/pyproject.toml`, `uv.lock`) and reads credentials from
  `api-poc/api/.env` (template: `.env.template`).
- Test targets: `TigerDuckTests` (phone unit tests), `TigerDuckWatch Watch AppTests` (watch) and
  `TigerDuckUITests` (UI, not run in CI). The vendored SwiftMail package has its own tests.
  The scripts in `tools/` have `unittest` tests next to them; `api-poc/` has none.
- Localization covers 67 locales and is generated in the `app-translation` submodule. What's New
  feature-page copy is the exception: zh-Hant and English, written in the app.
- The app and Watch app targets, unlike the others, default to `@MainActor`
  (`SWIFT_DEFAULT_ACTOR_ISOLATION`). Mark a type used off the main actor there `nonisolated`, or
  its synthesized conformances are main-actor isolated, a Swift 5 warning and a Swift 6 error.

## Anti-patterns

- Do not edit the `*.lproj` files under `swift/`; they are symlinks into the `app-translation`
  submodule, which takes its own pull requests.
- Do not treat `api-poc/api/runtime/` (for example `bulletin_pages/`) as source; it is
  gitignored scraper output.
- Do not look for a web backend here; it lives in `tigerduck-backend`.
- Do not add a Swift file to the app target without assigning it a platform: add it to both
  `INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]` arrays in `project.pbxproj` (Debug and Release) or
  list it in `tools/macos-excluded-sources.txt`. `tools/check_macos_sources.py` fails otherwise.

## Comments

Swift comments follow these rules. `tools/check_comments.py` enforces language, citations and
length in CI and, in Claude Code, after every edit (`.claude/hooks/check-comments.sh`); review
applies the rest. Before pushing, run `python3 tools/check_comments.py check --base origin/dev`.

- Write comments in English. String literals may hold Chinese, comments may not.
- Say why: a reason, an invariant or a non-obvious constraint. Do not restate the code or tell
  its history; git keeps the history.
- Keep a regular comment block to 3 lines and a doc comment to 8.
- Cite only what a reader can open: repository paths, RFC sections, Apple documentation, issue
  and pull request URLs. Never cite review rounds, dispatch or task numbers, sections of
  documents outside the repository, OpenSpec changes or paths, or agent and tool names.
- Do not record who decided something or what a pull request discussion said; write the reason.
- Use plain wording: no bold, no `IMPORTANT:` or `NOTE:`, no em dashes, and no "exactly",
  "deliberately", "intentionally" or "note that" as emphasis.
- Put longer knowledge where it belongs: rationale that spans files in an ADR under
  `docs/decisions/` with a one-line pointer in the code, procedures in a skill, agent rules in
  the nearest AGENTS.md, and described behavior in a test.

## Planning

- Use an OpenSpec change (the `openspec-propose` skill, `/opsx:propose` in Claude Code) only for
  work that spans sessions, changes the architecture or needs both maintainers to agree. Plan
  smaller work in plan mode or with `/feature-dev`.
- Changes live in `openspec/changes/<name>/`, are written in English and are committed with the
  work. Archive one with `openspec archive <name>` after its last pull request merges.
- After upgrading the CLI, run `openspec update` and commit the regenerated skill files with the
  new version in the install line above.
- Specs may cite code; code never cites a change name, an `openspec/` path or a spec section,
  because archiving moves the files.
- Never write plans or specs to an ignored path.

## Gotchas

- CI runs the unit tests on a `macos-26` runner in the Asia/Taipei timezone.
- Every pull request to `main` or `dev` fails while a submodule is behind its upstream branch;
  bump the submodule first.
- Pull requests from `dev` to `main` must raise `MARKETING_VERSION` by one SemVer step, or keep
  it and raise `CURRENT_PROJECT_VERSION` by exactly 1, and `swift/TigerDuck/whatsnew.json` must
  have an entry for the marketing version. The `release-bump` skill does this.
- `swift/TigerDuckWatchWidget/` is not referenced by `project.pbxproj`; no target builds it.
- `swift/Packages/SwiftMail/` is vendored; read its `VENDORED.md` before changing it.
- Xcode Cloud runs `swift/ci_scripts/ci_post_clone.sh` after cloning; it fetches the submodules.
- Dependabot updates the Swift packages (`.github/dependabot.yml`) and Renovate the rest
  (`.github/renovate.json`). A Swift update fails `licenses.yaml` until
  `python3 tools/generate_licenses.py` runs on its branch and the result is committed.
