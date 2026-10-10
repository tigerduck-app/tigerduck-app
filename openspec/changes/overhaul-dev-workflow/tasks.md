# Tasks

All work lands on one local branch, `chore/workflow-overhaul` from `dev`, in small ASCII-only
Conventional Commits signed with `git commit -S`. Nothing is pushed until every local task is
done; then the branch goes up as one pull request to `dev`, after the maintainer approves that
push (group 12). Local test destination: `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5`.

## 1. Proposal and OpenSpec setup

- [x] 1.1 Initialize OpenSpec with `openspec init --tools claude,codex` and commit the generated files; verify `openspec list --json` reports a root
- [x] 1.2 Set the context and rules in `openspec/config.yaml`; verify `openspec instructions proposal --change overhaul-dev-workflow --json` returns them
- [x] 1.3 Write proposal, specs, design and tasks; verify `openspec validate overhaul-dev-workflow --strict` passes
- [x] 1.4 Restructure the plan for one local branch and one pull request; verify `openspec validate overhaul-dev-workflow --strict` passes

## 2. Agent settings

- [x] 2.1 Set `enabledPlugins` in `.claude/settings.json` to `swift-lsp`, `feature-dev` and `pr-review-toolkit` from `claude-plugins-official`; verify `jq '.enabledPlugins | keys' .claude/settings.json` prints exactly those three
- [x] 2.2 Put the maintainer's personal plugins (`code-review`, `commit-commands`, `hookify`, `ralph-loop`, `dev-browser`, `plugin-dev`) in `.claude/settings.local.json` (never committed) and drop its superpowers permission entries; verify a new Claude Code session lists the personal plugins and no superpowers or claude-mem
- [x] 2.3 Delete `skills-lock.json`; verify `git ls-files skills-lock.json` prints nothing
- [x] 2.4 Delete the untracked local `docs/superpowers/` and `.superpowers/`, then remove both entries from `.gitignore`; verify `git check-ignore docs/superpowers .superpowers` prints nothing and `git status` shows no new files
- [x] 2.5 Move `release-bump` to `.agents/skills/release-bump/` and make `.claude/skills/release-bump` a relative symlink to that folder; verify Claude Code and Codex both list `release-bump` in a fresh session

## 3. AGENTS.md and contributor docs

- [x] 3.1 Rewrite the root AGENTS.md: rules agents cannot discover, a Comments section summarizing `specs/code-comments`, a Planning section (OpenSpec threshold, citation direction, `npm install -g @fission-ai/openspec`, `OPENSPEC_TELEMETRY=0`), setup for `(cd swift && xcode-build-server config -project TigerDuck.xcodeproj -scheme TigerDuck)`, which writes the ignored `swift/buildServer.json`, the verification commands, and the warning that CLAUDE.md or CLAUDE.local.md hides AGENTS.md from Claude Code; verify every command in the file runs as written
- [x] 3.2 Rewrite `swift/TigerDuck/AGENTS.md` without the structure tree, replacing the `AppState` coordination convention with "add no new responsibilities to `AppState`; feature state lives in the feature's view model or service"; verify no AGENTS.md still tells agents to put shared coordination in `AppState`
- [x] 3.3 Rewrite `swift/TigerDuck/Services/AGENTS.md`, `swift/TigerDuck/LiveActivity/AGENTS.md`, `swift/TigerDuck/Services/Migrations/AGENTS.md` and `api-poc/api/AGENTS.md` the same way; verify no file keeps a directory tree or file inventory
- [x] 3.4 Add the comment policy and OpenSpec usage to the contributing sections of `README.md` (in Chinese, as that file is) and `README.en.md`; verify the maintainer approves the exact wording before the push
- [x] 3.5 Add a status note at the top of `docs/third-party-migration-plan.md`: which of the nine libraries are in, and which architecture-debt items still hold; verify each library against `Package.resolved`

## 4. Comment tooling

- [x] 4.1 Write `tools/check_comments.py` with the lexer, `check` (rules `han`, `trace`, `tool`, `openspec`, `length`; options `--base`, `--all`) and `same-tokens`, as in design.md; verify `python3 tools/check_comments.py check --all` on the tree before the cleanup reports 235 `trace` lines in 78 files and 335 `han` lines in 81 files
- [x] 4.2 Write `tools/test_check_comments.py` with `unittest`: nested block comments, raw and multi-line strings, interpolation holding strings and parentheses, `#/.../#`, `//` inside strings, each rule, the RFC exemption, changed-block detection, and `same-tokens` ignoring a comment edit but catching a code edit; verify `python3 -m unittest discover -s tools -p 'test_*.py'` passes

## 5. Characterization tests

- [x] 5.1 Check the rules described by the long comments on `MailListViewModel.mergeFreshPage` and `AppState+NotificationSettings.swift`'s `assignmentsSection` against the tests and add a test for each rule not yet covered (other behavior-describing comments are flagged during the cleanup in group 6); verify the phone unit tests pass locally and each new test fails when its rule is broken

## 6. Comment cleanup (one comment-only commit range per area)

Each range: classify every flagged block with the outcomes table in design.md, translate Chinese,
move cross-file rationale to `docs/decisions/`, procedures to `.agents/skills/` and agent rules to
AGENTS.md, then verify `python3 tools/check_comments.py same-tokens <commit before the range>`
exits 0, `python3 tools/check_comments.py check PATH...` is clean for the area, the phone and
watch unit tests and the macOS build pass, and a review subagent finds no lost or wrong statement.

- [x] 6.1 School Mail: `swift/TigerDuck/Features/SchoolMail/`, `swift/TigerDuck/Services/Mail/` and their tests
- [x] 6.2 Settings sync and Live Activity: `App/`, `Services/Sync/`, `Services/CloudSync/`, `Services/Push/`, `LiveActivity/`, `Features/Settings/`, `Platform/Mac/` and their tests
- [x] 6.3 The rest of the app: `swift/Shared/`, the remaining `Features/` and `Services/`, `Theme/`, `Bridge/`, `Shared/`, `swift/TigerDuckWidgets/`, `swift/TigerDuckLiveActivity/`, `swift/TigerDuckWatch Watch App/`, `swift/TigerDuckWatchWidget/`
- [x] 6.4 The remaining test files in `swift/TigerDuckTests/`, `swift/TigerDuckUITests/` and `swift/TigerDuckWatch Watch AppTests/`
- [x] 6.5 Verify `python3 tools/check_comments.py check --all` reports nothing after the last range

## 7. Enforcement

- [x] 7.1 Add `.github/workflows/comments.yaml` on `ubuntu-latest`: the unit tests, `check --base HEAD^1` on pull requests (checkout `fetch-depth: 2`) and `check --all` on pushes to `dev` and `main`; verify locally that `check --base HEAD^1` on a scratch commit with a planted `(fix round 1)` exits non-zero with a `::error` annotation and exits zero once it is removed
- [x] 7.2 Add the `PostToolUse` hook (matcher `Edit|Write`) to `.claude/settings.json`: read `.tool_input.file_path` (with `python3`, so the hook needs nothing beyond the checker), run `check --base HEAD` on Swift files, exit 2 with the report on stderr; verify that editing a Swift file in Claude Code to add `(fix round 2)` brings the finding back to the agent
- [x] 7.3 Add the comment rule to `.greptile/rules.md` and rewrite the last rule without its typo and complaint; verify on the pull request that Greptile applies it (12.3)

## 8. CI path gating

- [x] 8.1 In both unit-test legs of `.github/workflows/tests.yaml`, check out with `fetch-depth: 2` on pull requests, compute `docs_only` from `git diff --name-only HEAD^1 HEAD`, run the later steps only when it is false, and log the skip; verify locally that the gating command calls a documentation-only file list skippable and a list with a Swift or workflow file not
- [x] 8.2 Gate the SwiftMail job's `swift test` on changes under `swift/Packages/SwiftMail/` or to `tests.yaml`, always running on pushes; verify locally that the gate skips for an app-only file list and runs for a SwiftMail or `tests.yaml` change
- [x] 8.3 Condense the comments in `tests.yaml` that this work touches to the comment policy; verify the maintainer approves the diff

## 9. Tests without wall-clock waits

- [x] 9.1 Give the Watch sync debounce an injectable clock or duration and rewrite `WatchSyncCoordinatorTests` without the 700 ms sleep; verify the suite passes 20 times with `-test-iterations 20`
- [x] 9.2 Do the same for `WidgetReloadCoordinator` (200 ms), the notification settings push queue (200 ms and polling) and push registration (250 ms debounce); verify each suite passes 20 times
- [x] 9.3 Replace the fixed layout waits in `PagingScrollLockTests` and `PullToRevealSearchTests`, and the short `Thread.sleep` calls in `ClockCoreTests` and `MailStoreTests`, with condition polling or signals; verify a search of the test targets for `Task.sleep`, `Thread.sleep` and `usleep` only finds fakes and cancelled placeholders

## 10. Simulator boot during the build

- [x] 10.1 Start `xcrun simctl boot` in the background before the build and wait with `simctl bootstatus -b` after it; verify locally that the step script boots a shut-down simulator and the test step finds it booted; the keep-or-revert decision comes from the pull request's runs (12.4) (dropped before it ran: `tests.yaml` records that booting during the build cost xcodebuild 68 to 171 s of start-up and 33 to 96 s of package graph)

## 11. Suites off the main actor

- [x] 11.1 Remove `@MainActor` from each of the 49 annotated test files that uses no main-actor API; verify the phone and watch unit tests pass and three local runs' "ran for" times beat three runs without the change, and revert it otherwise (reverted, 2 suites: Swift Testing 2.94/2.57/2.47 s and wall 22.8/11.6/10.9 s without, 2.67/2.48/2.61 s and 20.9/11.0/11.2 s with)

## 12. Pull request

- [x] 12.1 Ask the maintainer to approve the push, then push `chore/workflow-overhaul` and open one pull request to `dev` whose description maps each commit range to its task group; verify every check runs
- [ ] 12.2 Ask SamWang8891 to review `specs/code-comments/spec.md` and the new `AppState` rule in `swift/TigerDuck/AGENTS.md`; verify both maintainers approve (deferred by the maintainer on 2026-10-10)
- [ ] 12.3 Address valid Greptile comments, pushing only with the maintainer's approval; verify Greptile's review applies the comment rule
- [ ] 12.4 Record the pull request's "ran for" times against the `dev` baseline (175 to 183 s) in the description; its whole-job times are not compared, because pull-request runs do not save caches
- [ ] 12.5 After the merge, ask the maintainer to make the comment check required for `dev` and `main`, confirm that the first documentation-only pull request passes both unit-test legs in under two minutes, and archive the change with `openspec archive overhaul-dev-workflow`

## 13. Contributor templates and dependency bots

- [x] 13.1 Add English issue templates for bugs and feature requests, a template chooser whose only link is private security reporting, and a pull request template that follows the README contributing list, with README item 4 asking for Greptile's 5/5 instead of a Copilot review; verify the maintainer approves the wording before the push
- [ ] 13.2 Add `.github/dependabot.yml` for the Xcode project's Swift packages and `.github/renovate.json` for GitHub Actions, the `api-poc` uv project and the submodules, both opening pull requests against `dev`; verify `renovate-config-validator --strict` passes and, once the next release reaches `main`, that each bot opens its first pull request against `dev`
- [x] 13.3 Write the labeling guide in `docs/issue-triage.md`, set the label descriptions it relies on, add `dependencies`, drop `duplicate`, `invalid` and `wontfix`, and set the issue type from the templates; verify the maintainer approves the proposal before any label changes

## Workflow follow-up

- If the phone leg is still well above 5 minutes, propose a separate change for extracting pure
  logic into a Swift package or for a larger runner.
