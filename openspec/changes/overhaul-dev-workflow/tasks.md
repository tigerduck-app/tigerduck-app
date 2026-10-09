# Tasks

Every pull request targets `dev`, uses ASCII-only Conventional Commits signed with `git commit -S`,
lands in small commits, and is pushed only after the maintainer approves that push. Local test
destination: `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5`.

## 1. Proposal and OpenSpec setup (branch docs/openspec-overhaul-proposal)

- [x] 1.1 Initialize OpenSpec with `openspec init --tools claude,codex` and commit the generated files; verify `openspec list --json` reports a root
- [x] 1.2 Set the context and rules in `openspec/config.yaml`; verify `openspec instructions proposal --change overhaul-dev-workflow --json` returns them
- [x] 1.3 Write proposal, specs, design and tasks; verify `openspec validate overhaul-dev-workflow --strict` passes
- [ ] 1.4 Open the pull request after the maintainer approves the push, and ask SamWang8891 to review `specs/code-comments/spec.md`; verify both maintainers approve

## 2. Agent settings (branch chore/agent-settings)

- [ ] 2.1 Set `enabledPlugins` in `.claude/settings.json` to `swift-lsp`, `feature-dev` and `pr-review-toolkit` from `claude-plugins-official`; verify `jq '.enabledPlugins | keys' .claude/settings.json` prints exactly those three
- [ ] 2.2 Put the maintainer's personal plugins in `.claude/settings.local.json` (never committed) and drop its superpowers permission entries; verify a new Claude Code session lists the personal plugins and no superpowers or claude-mem
- [ ] 2.3 Delete `skills-lock.json`; verify `git ls-files skills-lock.json` prints nothing
- [ ] 2.4 Delete the untracked local `docs/superpowers/` and `.superpowers/`, then remove both entries from `.gitignore`; verify `git check-ignore docs/superpowers .superpowers` prints nothing and `git status` shows no new files
- [ ] 2.5 Move `release-bump` to `.agents/skills/release-bump/` and make `.claude/skills/release-bump/SKILL.md` a relative symlink to it; verify Claude Code and Codex both list `release-bump` in a fresh session

## 3. AGENTS.md and contributor docs (branch docs/agents-rewrite)

- [ ] 3.1 Rewrite the root AGENTS.md: rules agents cannot discover, a Comments section summarizing `specs/code-comments`, a Planning section (OpenSpec threshold, citation direction, `npm install -g @fission-ai/openspec`, `OPENSPEC_TELEMETRY=0`), setup for `xcode-build-server config -project swift/TigerDuck.xcodeproj -scheme TigerDuck`, the verification commands, and the warning that CLAUDE.md or CLAUDE.local.md hides AGENTS.md from Claude Code; verify every command in the file runs as written
- [ ] 3.2 Rewrite `swift/TigerDuck/AGENTS.md` without the structure tree, replacing the `AppState` coordination convention with "add no new responsibilities to `AppState`; feature state lives in the feature's view model or service"; verify SamWang8891 approves the new rule
- [ ] 3.3 Rewrite `swift/TigerDuck/Services/AGENTS.md`, `swift/TigerDuck/LiveActivity/AGENTS.md`, `swift/TigerDuck/Services/Migrations/AGENTS.md` and `api-poc/api/AGENTS.md` the same way; verify no file keeps a directory tree or file inventory
- [ ] 3.4 Add the comment policy and OpenSpec usage to the contributing sections of `README.md` (in Chinese, as that file is) and `README.en.md`; verify the maintainer approves the exact wording before the push
- [ ] 3.5 Add a status note at the top of `docs/third-party-migration-plan.md`: Valet, SwiftSoup, Sentry and Defaults are done, Alamofire is not, the architecture-debt section still holds; verify each library against `Package.resolved`

## 4. Comment tooling (branch feat/comment-checker)

- [ ] 4.1 Write `tools/check_comments.py` with the lexer, `check` (rules `han`, `trace`, `tool`, `openspec`, `length`; options `--base`, `--all`) and `same-tokens`, as in design.md; verify `python3 tools/check_comments.py check --all` on `dev` reports 235 `trace` lines in 78 files and 335 `han` lines in 81 files
- [ ] 4.2 Write `tools/test_check_comments.py` with `unittest`: nested block comments, raw and multi-line strings, interpolation holding strings and parentheses, `#/.../#`, `//` inside strings, each rule, the RFC exemption, changed-block detection, and `same-tokens` ignoring a comment edit but catching a code edit; verify `python3 -m unittest discover -s tools -p 'test_*.py'` passes

## 5. Characterization tests (branch test/comment-behaviors)

- [ ] 5.1 List the long comments that describe testable behavior (start with `MailListViewModel.mergeFreshPage` and the JSON-level merge in `AppState+NotificationSettings.swift`) and add a test for each rule not yet covered; verify the phone unit tests pass locally and in CI

## 6. Comment cleanup (one comment-only pull request per area)

Each pull request: classify every flagged block with the outcomes table in design.md, translate
Chinese, move cross-file rationale to `docs/decisions/`, procedures to `.agents/skills/` and agent
rules to AGENTS.md, then verify `python3 tools/check_comments.py same-tokens origin/dev` exits 0,
`python3 tools/check_comments.py check PATH...` is clean for the area, the phone and watch unit
tests and the macOS build pass, and a review subagent finds no lost or wrong statement.

- [ ] 6.1 School Mail: `swift/TigerDuck/Features/SchoolMail/`, `swift/TigerDuck/Services/Mail/` and their tests
- [ ] 6.2 Settings sync and Live Activity: `App/`, `Services/Sync/`, `Services/CloudSync/`, `Services/Push/`, `LiveActivity/`, `Features/Settings/`, `Platform/Mac/` and their tests
- [ ] 6.3 The rest of the app: `swift/Shared/`, the remaining `Features/` and `Services/`, `Theme/`, `Bridge/`, `Shared/`, `swift/TigerDuckWidgets/`, `swift/TigerDuckLiveActivity/`, `swift/TigerDuckWatch Watch App/`, `swift/TigerDuckWatchWidget/`
- [ ] 6.4 The remaining test files in `swift/TigerDuckTests/`, `swift/TigerDuckUITests/` and `swift/TigerDuckWatch Watch AppTests/`
- [ ] 6.5 Verify `python3 tools/check_comments.py check --all` reports nothing on `dev` after the last cleanup merges

## 7. Enforcement (branch ci/comment-check)

- [ ] 7.1 Add `.github/workflows/comments.yaml` on `ubuntu-latest`: the unit tests, `check --base HEAD^1` on pull requests (checkout `fetch-depth: 2`) and `check --all` on pushes to `dev` and `main`; verify a throwaway pull request with a planted `(fix round 1)` fails with an annotation, and passes once it is removed
- [ ] 7.2 Add the `PostToolUse` hook (matcher `Edit|Write`) to `.claude/settings.json`: read `.tool_input.file_path` with `jq`, run `check --base HEAD` on Swift files, exit 2 with the report on stderr; verify that editing a Swift file in Claude Code to add `(fix round 2)` brings the finding back to the agent
- [ ] 7.3 Add the comment rule to `.greptile/rules.md` and rewrite the last rule without its typo and complaint; verify the next Greptile review applies it
- [ ] 7.4 Ask the maintainer to make the comment check required for `dev` and `main`; verify in the branch protection settings

## 8. CI path gating (branch ci/path-gating)

- [ ] 8.1 In both unit-test legs of `.github/workflows/tests.yaml`, check out with `fetch-depth: 2` on pull requests, compute `docs_only` from `git diff --name-only HEAD^1 HEAD`, run the later steps only when it is false, and log the skip; verify a documentation-only pull request passes both legs in under two minutes and a Swift pull request runs fully
- [ ] 8.2 Gate the SwiftMail job's `swift test` on changes under `swift/Packages/SwiftMail/` or to `tests.yaml`, always running on pushes; verify an app-only pull request skips it with a log line
- [ ] 8.3 Condense the comments in `tests.yaml` that this pull request touches to the comment policy; verify the maintainer approves the diff
- [ ] 8.4 Record step timings of three runs of each kind in the pull request description

## 9. Tests without wall-clock waits (branch test/deterministic-timing)

- [ ] 9.1 Give the Watch sync debounce an injectable clock or duration and rewrite `WatchSyncCoordinatorTests` without the 700 ms sleep; verify the suite passes 20 times with `-test-iterations 20`
- [ ] 9.2 Do the same for `WidgetReloadCoordinator` (200 ms), the notification settings push queue (200 ms and polling) and push registration (250 ms debounce); verify each suite passes 20 times
- [ ] 9.3 Replace the fixed layout waits in `PagingScrollLockTests` and `PullToRevealSearchTests`, and the short `Thread.sleep` calls in `ClockCoreTests` and `MailStoreTests`, with condition polling or signals; verify a search of the test targets for `Task.sleep`, `Thread.sleep` and `usleep` only finds fakes and cancelled placeholders
- [ ] 9.4 Record the phone leg "ran for" times of three runs against the 175 to 183 s baseline

## 10. Simulator boot during the build (branch ci/boot-overlap)

- [ ] 10.1 Start `xcrun simctl boot` in the background before the build and wait with `simctl bootstatus -b` after it; keep the change only if three warm pull-request runs beat the 601 to 656 s phone-leg baseline, recorded in the pull request description

## 11. Suites off the main actor (branch test/nonisolated-suites)

- [ ] 11.1 Remove `@MainActor` from each of the 49 annotated test files that uses no main-actor API; verify the phone and watch unit tests pass and three runs' "ran for" times beat the baseline

## Workflow follow-up

- Archive with `openspec archive overhaul-dev-workflow` once every pull request has merged.
- If the phone leg is still well above 5 minutes, propose a separate change for extracting pure
  logic into a Swift package or for a larger runner.
