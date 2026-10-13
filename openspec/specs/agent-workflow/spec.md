# agent-workflow Specification

## Purpose
Define how coding agents and both maintainers share rules, plans, skills and plugins in this
repository, so every agent reads the same rules and every plan is readable by everyone.

## Requirements

### Requirement: AGENTS.md is the only rule file
Agent rules SHALL live in AGENTS.md files, at the root and in subdirectories. The repository
SHALL NOT contain a CLAUDE.md or CLAUDE.local.md, because either one stops Claude Code from
loading AGENTS.md, and Codex reads only AGENTS.md.

#### Scenario: Claude Code session
- **WHEN** a Claude Code session starts at the repository root
- **THEN** it loads the root AGENTS.md as project instructions, and nested ones when it reads files in their directories

#### Scenario: Someone adds CLAUDE.local.md
- **WHEN** a maintainer is about to add a CLAUDE.md or CLAUDE.local.md
- **THEN** the root AGENTS.md tells them that it would hide AGENTS.md from Claude Code

### Requirement: AGENTS.md holds only what agents cannot discover
Each AGENTS.md SHALL contain conventions, anti-patterns, gotchas and commands that cannot be read
off the code, and SHALL NOT contain directory trees, file inventories or overviews that an agent
gets by listing the directory.

#### Scenario: Reviewing an AGENTS.md change
- **WHEN** a pull request adds a directory tree or a list of files to an AGENTS.md
- **THEN** review asks for it to be removed

### Requirement: New work does not grow AppState
The app AGENTS.md SHALL tell agents not to add responsibilities to `AppState`, and to keep
feature state in the feature's view model or service.

#### Scenario: Agent adds feature state
- **WHEN** an agent plans to add a stored property for one feature to `AppState`
- **THEN** the app AGENTS.md rule directs it to the feature's own view model or service

### Requirement: Plans are committed
Plans for work that spans sessions, changes the architecture, or needs both maintainers to agree
SHALL be OpenSpec changes under `openspec/changes/`, committed and reviewed like code. No tool
SHALL write plans or specs to an ignored path, and `.gitignore` SHALL NOT hide plan or spec
directories.

#### Scenario: Cross-session work
- **WHEN** a maintainer starts work that will span several sessions
- **THEN** it starts as an OpenSpec change, which is committed with the first pull request

#### Scenario: Ignored spec directories
- **WHEN** someone reads `.gitignore`
- **THEN** it has no entry for `docs/superpowers` or `.superpowers/`

### Requirement: Small work skips OpenSpec
Work that fits one session, keeps the architecture and needs no second maintainer's agreement
SHALL NOT get an OpenSpec change; it goes through plan mode or `/feature-dev`.

#### Scenario: Bug fix
- **WHEN** an agent fixes a bug in one feature
- **THEN** it plans in plan mode or `/feature-dev` and creates no OpenSpec change

### Requirement: OpenSpec artifacts are in English
Every proposal, design, task list and spec SHALL be written in English.

#### Scenario: New change
- **WHEN** an agent writes a proposal
- **THEN** it is in English, as `openspec/config.yaml` instructs

### Requirement: The team plugin set is minimal
The committed `.claude/settings.json` SHALL enable only `swift-lsp`, `feature-dev` and
`pr-review-toolkit` from the official marketplace. Plugins a maintainer wants for themselves go
in `.claude/settings.local.json` or their user settings, which are never committed.

#### Scenario: Reading the committed settings
- **WHEN** someone lists `enabledPlugins` in `.claude/settings.json`
- **THEN** they see exactly those three plugins, and neither superpowers nor claude-mem

### Requirement: Generated agent files are committed and current
The OpenSpec skills and commands for Claude Code (`.claude/`) and Codex (`.agents/skills/`) SHALL
be committed. A pull request that changes the OpenSpec CLI version SHALL include the files that
`openspec update` regenerates.

#### Scenario: CLI upgrade
- **WHEN** a maintainer upgrades OpenSpec and runs `openspec update`
- **THEN** the regenerated files are committed in the same pull request

### Requirement: Repository skills reach both agents
A skill written for this repository SHALL have its files in `.agents/skills/<name>/`, which Codex
loads, and `.claude/skills/<name>` SHALL be a relative symlink to that folder for Claude Code.

#### Scenario: Adding a procedure skill
- **WHEN** a procedure moves out of a comment into a skill
- **THEN** both Claude Code and Codex list the skill in a fresh session

### Requirement: Setup steps are documented
The root AGENTS.md SHALL document installing the OpenSpec CLI, opting out of its telemetry with
`OPENSPEC_TELEMETRY=0`, and generating the gitignored `swift/buildServer.json` with
xcode-build-server so `swift-lsp` can resolve the Xcode project.

#### Scenario: New machine
- **WHEN** a maintainer sets up a new machine
- **THEN** following the root AGENTS.md gives them a working `openspec` command, telemetry off, and `swift-lsp` without false errors
