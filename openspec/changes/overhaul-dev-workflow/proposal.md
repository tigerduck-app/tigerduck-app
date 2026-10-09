# Proposal

## Why

Agent-written comments cite things nobody else can open. superpowers saved its specs to the
gitignored `docs/superpowers/`, so 235 comment lines in 78 Swift files cite `spec §6`,
`design doc §9.3`, `fix round 1, important 4` or `dispatch addition 3`, which only make sense on
the machine and in the session that wrote them. Comments are 25.5% of non-blank app lines;
1,032 blocks run past three lines (regular) or eight (doc); 335 comment lines are in Chinese.
No file in the repository says what a comment should hold, so every agent falls back to its own
habits. Separately, the phone CI leg takes 10 to 11 minutes on every pull request, documentation
included.

## What Changes

- Drop superpowers and claude-mem from the committed Claude Code settings. The team plugin set
  becomes `swift-lsp`, `feature-dev` and `pr-review-toolkit`; personal plugins move to each
  maintainer's local settings. Remove `skills-lock.json` and the `.gitignore` entries that hid
  `docs/superpowers` and `.superpowers/`.
- Adopt OpenSpec for Claude Code and Codex, committed under `openspec/`, `.claude/` and
  `.agents/skills/`, in English, for cross-session, architectural or two-maintainer work only.
- Define a comment policy: English only; at most 3 lines per regular block and 8 per doc block;
  only reasons, invariants and non-obvious constraints; no citation of review rounds, task
  numbers, documents outside the repository, OpenSpec changes or agent tools; no emphasis
  markers.
- Add `tools/check_comments.py`, a standard-library Python checker with a Swift lexer, and run it
  in CI, in a Claude Code hook and through a Greptile rule.
- Clean up every existing comment that breaks the policy in comment-only commits, proven by
  an unchanged Swift token sequence. Cross-file rationale moves to ADRs in `docs/decisions/`,
  procedures to agent skills, agent rules to AGENTS.md, and described behavior gets a test first.
- Rewrite all six AGENTS.md files so they hold only what an agent cannot discover from the code,
  and replace "app-wide coordination belongs in `AppState`" with a rule against adding new
  responsibilities to `AppState`. Update the README contributing sections and mark the done
  items in `docs/third-party-migration-plan.md`.
- CI: skip the Xcode legs for documentation-only pull requests, run the SwiftMail tests only when
  that package changes, remove wall-clock sleeps from tests, try booting the simulator during the
  build, and take pure-logic suites off the main actor. Every speed change ships with timings.

Out of scope: splitting `AppState`, consolidating SwiftData and `DataCache`, injecting
singletons and `Defaults`, extracting logic into a Swift package, larger paid runners, skipping
app setup in the test host, and Xcode MCP servers. Each of the structural items gets its own
change later.

## Capabilities

### New Capabilities

- `code-comments`: what Swift comments may contain, how long they may be, where longer knowledge
  lives, and how the checker enforces it.
- `agent-workflow`: how agents and maintainers share rules, plans, skills and plugins in this
  repository.
- `ci-test-gate`: which pull requests run which test jobs, and how tests stay independent of
  machine timing.

### Modified Capabilities

None. `openspec/specs/` is empty before this change.

## Impact

- About 300 Swift files in the app and its tests get comment-only edits; no behavior changes.
- New files: `tools/check_comments.py` and its tests, `.github/workflows/comments.yaml`,
  `docs/decisions/*.md`, procedure skills, and `openspec/`.
- Changed files: `.claude/settings.json`, `.gitignore`, the six AGENTS.md files, `README.md`,
  `README.en.md`, `.greptile/rules.md`, `.github/workflows/tests.yaml`,
  `docs/third-party-migration-plan.md`, and the tests and time-dependent app types that move to
  an injected clock.
- Both maintainers install the OpenSpec CLI (`npm install -g @fission-ai/openspec`) for the
  OpenSpec skills to work.
- SamWang8891 wrote 233 of the 235 process-trace lines and most long blocks; the comment policy
  needs his agreement on the pull request before it merges.
