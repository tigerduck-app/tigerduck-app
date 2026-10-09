# Design

## Context

See proposal.md (Why) for the motivation. Measured on `dev` at d115e3c1 (2026-10-08), Swift
files from `git ls-files`, vendored `swift/Packages/` excluded, with the Swift lexer described
below:

| Item | Value |
|---|---|
| App sources | 423 files, 48,239 code lines; comments 16,482 lines (25.5% of non-blank), 69% doc comments |
| Tests | 110 files, 1,088 test functions (CI counts 1,063: a parameterized test counts once); comments 18.0% |
| Process-trace lines | 235 in 78 files (233 by SamWang8891, September 2026) |
| Non-RFC `§` citations | 134 lines in 71 files; RFC section citations: 8 |
| Review rounds / dispatch numbers / dated rulings | 71 lines in 17 files / 32 in 12 / 19 in 11 |
| Comment lines with Han characters | 335 in 81 files; string literals with Han: 411 lines in 50 files |
| Regular blocks over 3 lines | 657 blocks in 231 files |
| Doc blocks over 8 lines | 375 blocks in 200 files |
| Markdown bold in comments | 80 lines in 38 files |

The specs cited by comments (`spec §4.x`, `spec §6`, `design doc §4` to `§9`) existed only on one
maintainer's machine. They are not salvaged: the shipped behavior on GitHub is the source of
truth, so each citation is replaced by the reason it stood for.

CI baseline: phone leg of `.github/workflows/tests.yaml`, pull-request runs with a warm cache
(runs 37740137651, 37632460337, 37626423830):

| Step | Seconds |
|---|---|
| Whole job | 601, 656, 642 |
| Checkout, cache restore, resolve, build | 164 to 191 (build alone 84 to 86) |
| Simulator boot | 107 to 174 |
| Test step | 238 to 278, of which the test bundle ran 175 to 183 ("ran for"), and about 35 s is xcodebuild starting up |
| Summary and job teardown | 51 to 67 |

The watch leg takes 288 to 386 s and the SwiftMail job 177 to 306 s, both in parallel with the
phone leg. Test bodies contain fixed sleeps of 50 ms to 700 ms; 49 test files are `@MainActor`.
The runner has 3 cores; the repository is public, so standard runners are free and larger ones
are billed.

## Goals / Non-Goals

**Goals:**

- One comment policy that both agents and both maintainers follow, enforced mechanically where a
  rule can be checked without judgment.
- An existing codebase that already passes the policy when enforcement turns on.
- No loss of the knowledge that long comments carry.
- Shorter waits for pull requests that cannot affect the app, and test timing that does not
  depend on runner load.

**Non-Goals:**

- Linting Python, YAML or shell. Those follow the policy by review, when someone edits them.
- Enforcing the plain-wording rules (em dashes, "exactly", bold) mechanically.
- Reaching a 5-minute phone leg at any cost; see Risks.

## Decisions

### A Python checker with its own Swift lexer, not SwiftLint

`tools/check_comments.py` uses only the Python standard library, like the other scripts in
`tools/`. A small lexer splits Swift into code, string and comment spans. It handles nested
block comments, `///` and `/** */`, string literals with escapes, multi-line `"""` strings, raw
strings with `#` delimiters, interpolation with nested parentheses and strings, and `#/.../#`
regex literals. Bare `/.../` regex literals count as code; the only one in the repository
(`Models/Domain/LicenseCatalog.swift`) holds no `//`, `/*` or quote, so it lexes correctly.

Alternatives: SwiftLint `custom_rules` with `match_kinds: [comment, doccomment]` catches the
patterns and shows warnings in Xcode, but it cannot measure block length or compare tokens, so a
script would be needed anyway, and every machine plus CI would have to install SwiftLint, which
the app does not use today. SwiftSyntax gives an exact parse but needs a Swift package built in
CI, which turns a seconds-long check into minutes.

The prototype lexer reproduced the measurements above, including the 235 trace lines in 78
files, which is the acceptance test for the real implementation.

### Checker interface

- `check [--base REF] [--all] [PATH ...]` reports `path:line: rule: message` and exits 1 on
  findings, 2 on usage or git errors, 0 when clean. Under `GITHUB_ACTIONS` it also prints
  `::error file=...,line=...::` annotations. Without paths it checks the Swift files changed
  since `--base`, or every tracked Swift file with `--all`. `swift/Packages/` is always excluded.
- Rules: `han` (Han characters in a comment), `trace` (review rounds, dispatch numbers, non-RFC
  `§` citations), `tool` (agent and tool names), `openspec` (an `openspec/` path), and `length`
  (blocks over 3 regular or 8 doc lines; with `--base`, only blocks containing a line added or
  changed since the base, from `git diff -U0`).
- `same-tokens REF` compares, for every Swift file changed since `REF`, the token sequence with
  comments removed (strings as whole tokens, code split on whitespace). It names each file whose
  tokens differ and exits 1, which proves a cleanup is comment-only.
- The trace pattern starts from the measured regex:
  `(?i)fix round \d|dispatch(,? [0-9-]+)? addition|\((critical|important|minor) \d+\)|(?<!RFC \d{4} )(?<!RFC \d{3} )§ ?\d`
- `tools/test_check_comments.py` (standard `unittest`) covers the lexer edge cases, every rule,
  the RFC exemption, changed-block detection and `same-tokens`; CI runs it with the checker.

### Length limit applies to changed blocks

With `--base`, the length rule reports only blocks that contain an added or changed line, so a
later change to the limits does not force a repository-wide sweep, and an edit inside an old long
block forces that block to shrink. The cleanup still brings every block within the limit, so a
`check --all` run on the finished cleanup must be clean; pushes to `dev` and `main` run
`check --all`.

Alternative: check the whole repository on every pull request. It gives the same result after
the cleanup but fails every pull request the day a limit tightens.

### Enforcement points

- CI: `.github/workflows/comments.yaml` on `ubuntu-latest`, for pull requests to `main` and `dev`
  (`check --base HEAD^1` on the merge commit, checked out with `fetch-depth: 2`, plus the unit
  tests) and for pushes to them (`check --all`).
- Claude Code: a `PostToolUse` hook with matcher `Edit|Write` in `.claude/settings.json` reads
  `.tool_input.file_path` from the hook's stdin with `jq`, runs
  `check --base HEAD "$file"` for `.swift` files, and on findings exits 2 with the report on
  stderr, which Claude Code shows to the agent.
- Greptile: one rule in `.greptile/rules.md` that summarizes the policy, so pull requests from
  Codex also get review comments. The last existing rule, "Greptile review", is rewritten
  without the typo and the complaint.
- Codex has no hook; CI covers it.

Alternative: a git pre-commit hook. Every maintainer would have to install it, and an agent can
bypass it.

### Cleanup in comment-only pull requests, by area

Every block that breaks the policy gets one of these outcomes:

| Kind | Outcome |
|---|---|
| Process trace (review round, dispatch, outside spec section) | Deleted, or rewritten as the one-line reason it stood for |
| Change history | Deleted |
| Invariant or non-obvious constraint | Kept, condensed within the limit |
| Rationale for a decision that spans files | ADR in `docs/decisions/NNNN-slug.md`, with a one-line pointer in the code; rationale for one file stays, condensed |
| Procedure (pin generation and rotation, release steps) | Skill in `.agents/skills/<name>/`, linked from `.claude/skills/<name>/SKILL.md` |
| Behavior described in prose | Test first, in an earlier pull request; then the comment shrinks |
| Rule addressed to agents | Nearest AGENTS.md |
| Restates the code | Deleted |
| Chinese | Translated to English and condensed by the same rules |

Areas, one pull request each, about 60 to 90 files: School Mail (`Features/SchoolMail`,
`Services/Mail` and their tests); settings sync and Live Activity (`App/`, `Services/Sync`,
`Services/CloudSync`, `Services/Push`, `LiveActivity/`, `Features/Settings`, `Platform/Mac` and
their tests); the rest of the app (`swift/Shared`, the other `Features` and `Services`, `Theme`,
`Bridge`, widgets, the Live Activity extension, the Watch app); the remaining tests. A pull
request may add Markdown (ADRs, skills, AGENTS.md lines) next to its comment edits; it changes no
Swift token. Before each push a review subagent compares old and new comments for lost facts and
wrong statements.

Known ADR candidates: TLS pinning (threat model on campus Wi-Fi with a hostile MDM root, why a
delegate rather than `NSPinnedDomains`, fail-soft expiry), merging the notification settings
document at the JSON level so other features' keys survive, and the locked-down `WKWebView` for
mail. Known test candidates: `MailListViewModel.mergeFreshPage` treating an empty first page as
unknown rather than empty.

Alternatives: one pull request for all files (too large to review, and every in-flight branch
conflicts at once); cleaning only process traces and Chinese (leaves 1,032 long blocks that the
changed-block rule would surface piecemeal for years).

### Skills shared by Claude Code and Codex

Codex loads skills from `.agents/skills/`, Claude Code from `.claude/skills/`. A repository
skill keeps its real files in `.agents/skills/<name>/`, and `.claude/skills/<name>/SKILL.md` is a
relative symlink to the same file. Linking the file rather than the directory avoids depending on
whether a tool follows directory links. OpenSpec writes its own copies into both places, which
`openspec update` maintains. `release-bump` moves the same way so Codex can bump versions too.

### Plugins and personal settings

The committed set is `swift-lsp`, `feature-dev` and `pr-review-toolkit`. `code-review` overlaps
the `/code-review` command that Claude Code ships; `commit-commands`, `hookify`, `ralph-loop`,
`dev-browser` and `plugin-dev` are personal tools. Project settings outrank user settings, so a
plugin committed here was forced on everyone; the only way to opt out was a local override.
claude-mem is removed outright, from the repository and from the maintainer's machine.

### OpenSpec adoption

OpenSpec 1.14.1 for Claude Code and Codex, default `spec-driven` schema and core profile, with
generated files committed. `openspec/config.yaml` carries the English rule, the citation
direction and the usage threshold, so every artifact the skills write follows them. The CLI sends
anonymous usage statistics unless `OPENSPEC_TELEMETRY=0`; AGENTS.md documents the opt-out.

Alternative: leave the generated files untracked and have each maintainer run `openspec init`.
Cleaner history, but two machines could run different versions of the skills.

### AGENTS.md rewrite

All six files are rewritten: the root, `swift/TigerDuck/`, `Services/`, `LiveActivity/`,
`Services/Migrations/` and `api-poc/api/`. Each keeps conventions, anti-patterns, gotchas and,
at the root, commands; directory trees, code maps, file inventories and dated headers go. The
root gains sections for comments, planning with OpenSpec, setup (OpenSpec CLI, telemetry,
xcode-build-server) and the warning about CLAUDE.md and CLAUDE.local.md. No CLAUDE.md is added.

### CI gating inside the jobs

Each job checks out with `fetch-depth: 2` on pull requests and lists the pull request's files
with `git diff --name-only HEAD^1 HEAD` (the checkout is the merge commit, whose first parent is
the base). A step sets `docs_only` and `swiftmail` outputs; later steps run only when they apply,
and the skip is logged. Gating at the job level with `if:` would avoid starting a macOS runner,
but a skipped matrix job does not report its expanded check name (`unit-tests (phone)`), so a
required check could stay pending. A workflow-level `paths` filter has the same problem.

The time-dependent types used by the slow tests take an injected clock or duration (the Watch
sync debounce, widget reload, notification settings push queue, push registration). Layout waits
poll with the existing `WaitUntil` helper. Booting the simulator in the background during the
build and removing `@MainActor` from pure-logic suites are both experiments, kept only if the
measurements show a gain.

### Order of pull requests

Each topic is its own pull request against `dev`, opened only after the maintainer approves the
push.

1. This change and the OpenSpec setup (documentation only), so both maintainers can agree on the
   policy before any cleanup.
2. Agent settings: plugin set, `skills-lock.json`, `.gitignore` entries.
3. AGENTS.md rewrite, README contributing sections, migration plan status note.
4. Comment tooling: checker and its tests, not wired into CI.
5. Characterization tests for behavior described in long comments.
6. to 9. Comment cleanup, one pull request per area.
10. Enforcement: CI workflow, Claude Code hook, Greptile rule.
11. CI path gating (and the comments in `tests.yaml` it touches, condensed).
12. Tests without wall-clock waits.
13. Simulator boot during the build (measured).
14. Suites off the main actor (measured).

Steps 11 to 14 do not depend on 4 to 10 and can run in parallel with them. Every pull request can
be reverted on its own.

## Risks / Trade-offs

- [A repository-wide cleanup collides with in-flight branches] → Agree on the policy first, split
  by area, keep each pull request short-lived, and rebase in-flight branches right after each
  merge; comment-only edits conflict as text and are easy to resolve.
- [The lexer misreads an unusual construct] → Unit tests for each construct; the full-repository
  run must reproduce the measured counts; `same-tokens` failures are inspected by hand.
- [Condensing loses knowledge] → The outcomes table, ADRs and tests keep it; a review subagent
  compares old and new comments in every cleanup pull request.
- [Plain-wording rules depend on review] → Accepted; Greptile carries the rule.
- [Editing one line of a long block forces a rewrite] → Intended; after the cleanup no long blocks
  remain.
- [A documentation-only skip hides a broken build] → Workflow files and every non-documentation
  path still run both legs; pushes to `dev` and `main` always run everything.
- [OpenSpec adds a CLI dependency and telemetry] → Install and opt-out are documented; the skills
  fail visibly without the CLI.
- [The 5-minute phone leg is out of reach with these steps] → The estimate after path gating,
  boot overlap and main-actor removal is around 8 minutes, unmeasured. Extracting a Swift package
  or a larger runner would be a separate change.

## Open Questions

- Which personal plugins the maintainer keeps in `.claude/settings.local.json`. Assumed:
  `code-review`, `commit-commands`, `hookify`, `ralph-loop`, `dev-browser` and `plugin-dev`.
- Whether the OpenCode files (`oh-my-openagent.json`, the ignored `.sisyphus/`) are still used
  now that the team tools are Claude Code and Codex.
- Which check names branch protection requires; the in-job gating works for any of them.
