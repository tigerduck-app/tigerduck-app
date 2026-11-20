# code-comments Specification

## Purpose
Keep Swift comments short, in English and understandable from the repository alone, and enforce
the mechanical parts of that with a deterministic checker instead of prompts.

## Requirements

### Requirement: Comments state reasons, not narration
A Swift comment SHALL say only what the code cannot: a behaviour of Apple's platforms, the
school's servers, a dependency or a protocol that we cannot change, a contract callers rely on, a
license, or an issue or RFC link. It SHALL NOT restate what the code does or tell the history of
the code; history belongs in git. This rule is enforced in review.

#### Scenario: History narration in a pull request
- **WHEN** a pull request adds a comment saying how the code used to behave ("previously", "used to", "no longer")
- **THEN** review asks for it to be removed

#### Scenario: Restating the code
- **WHEN** a comment only repeats what the next line does
- **THEN** review asks for it to be removed

#### Scenario: A comment on our own design
- **WHEN** a comment explains why our own code is shaped the way it is, with no outside behaviour behind it
- **THEN** review asks for the name, type or state it stands in for, and for the comment to be removed

### Requirement: Comments are in English
A comment in a checked Swift file SHALL contain no Han characters. String literals are exempt,
because the app parses Chinese school pages and its tests use Chinese fixtures.

#### Scenario: Han characters in a comment
- **WHEN** a checked Swift file has a comment containing a Han character
- **THEN** `tools/check_comments.py check` reports the file, the line and the rule, and exits non-zero

#### Scenario: Han characters in a string literal
- **WHEN** a Swift string literal contains Han characters
- **THEN** the checker reports nothing for that literal

### Requirement: Comment blocks stay within the length limit
A run of consecutive comment-only lines of one kind SHALL be at most 3 lines for regular comments
(`//`, `/* */`) and at most 8 lines for documentation comments (`///`, `/** */`). With a base
revision given, the checker SHALL apply the limit only to blocks containing a line added or
changed since that base.

#### Scenario: A new block over the limit
- **WHEN** a pull request adds a regular comment block of 4 lines
- **THEN** the checker run against the pull request's base reports the block and exits non-zero

#### Scenario: One edited line inside a long block
- **WHEN** a pull request changes one line inside an existing 12-line doc comment
- **THEN** the checker reports the whole block

#### Scenario: An untouched block
- **WHEN** a block over the limit has no line changed since the base
- **THEN** the checker does not report it

#### Scenario: No base given
- **WHEN** the checker runs without a base on a list of files
- **THEN** it applies the limit to every block in those files

### Requirement: Comments cite only sources inside the repository or public references
A comment SHALL NOT cite a review round, a dispatch or task number, a section of a document
outside the repository, an OpenSpec change or path, or an agent or tool name. RFC sections,
Apple documentation, repository paths and issue or pull request URLs MAY be cited.

#### Scenario: Review round
- **WHEN** a comment contains `fix round 1` or `(important 4)`
- **THEN** the checker reports it

#### Scenario: Dispatch number
- **WHEN** a comment contains `dispatch addition 3` or `dispatch, 2026-09-16 addition 1`
- **THEN** the checker reports it

#### Scenario: Section of an outside document
- **WHEN** a comment contains `spec §6` or `design doc §9.3`
- **THEN** the checker reports it

#### Scenario: RFC section
- **WHEN** a comment contains `RFC 5322 §3.6`
- **THEN** the checker reports nothing for it

#### Scenario: OpenSpec reference
- **WHEN** a comment contains `openspec/` or the name of an OpenSpec change
- **THEN** the checker reports the path; review catches a bare change name

#### Scenario: Tool name
- **WHEN** a comment names Claude, Codex, Copilot, Greptile, CodeRabbit, superpowers, OpenCode, Sisyphus, BMad or OpenSpec
- **THEN** the checker reports it

### Requirement: Decisions and discussions are not recorded in comments
A comment SHALL NOT record who decided something and when (for example "Owner's ruling,
2026-09-12") or what a pull request discussion said. The comment states the resulting reason
instead. This rule is enforced in review.

#### Scenario: Dated ruling
- **WHEN** a pull request adds a comment that cites a ruling with a date
- **THEN** review asks for the reason to replace the ruling

### Requirement: Comments use plain wording
A comment SHALL NOT use Markdown bold, all-caps markers such as `IMPORTANT:` or `NOTE:`, em
dashes, or the words "exactly", "deliberately", "intentionally" and "note that" as emphasis.
This rule is enforced in review, because the same words often carry meaning ("exactly one").

#### Scenario: Emphasis markers
- **WHEN** a pull request adds `**always**`, `IMPORTANT:` or an em dash to a comment
- **THEN** review asks for plain wording

### Requirement: Long-form knowledge lives outside comments
Rationale for a decision that constrains several files SHALL be an ADR in `docs/decisions/`. A
procedure SHALL be an agent skill. A rule for agents SHALL be in the nearest AGENTS.md. Behaviour
that a comment describes in detail SHALL be pinned by a test before the comment is removed.

#### Scenario: Cross-file rationale
- **WHEN** a comment explains a decision that constrains several files, such as the TLS pinning threat model
- **THEN** the explanation moves to an ADR and the comment is removed

#### Scenario: Procedure in a comment
- **WHEN** a comment holds steps to run, such as generating or rotating TLS pins
- **THEN** the steps move to a skill under `.agents/skills/` that Claude Code also loads

#### Scenario: Behavior described in prose
- **WHEN** a long comment describes a merge rule, such as treating an empty first mail page as "unknown" rather than "empty folder"
- **THEN** a test pins the rule in an earlier commit, and the comment is removed

### Requirement: Comment cleanups leave the code unchanged
A commit range that only cleans up comments SHALL leave each changed Swift file's token
sequence, with comments removed, identical to the commit before the range.

#### Scenario: Comment-only range
- **WHEN** `tools/check_comments.py same-tokens <base>` runs on a range that changes only comments
- **THEN** it exits zero

#### Scenario: A code token changed
- **WHEN** the range also changes a code token or a string literal
- **THEN** it names the file and exits non-zero

### Requirement: CI blocks findings
The checker SHALL run in CI on every pull request to `main` and `dev` and on every push to them,
need nothing beyond Python 3, fail the job on any finding, and annotate each finding on its line.

#### Scenario: Pull request with a finding
- **WHEN** a pull request introduces a finding
- **THEN** the comment check fails and lists each finding as `path:line: rule: message`

#### Scenario: Clean pull request
- **WHEN** a pull request introduces no finding
- **THEN** the comment check passes within a minute

### Requirement: Claude Code checks each edited Swift file
When Claude Code writes or edits a Swift file in this repository, a project hook SHALL run the
checker on that file against `HEAD` and return any findings to the agent in the same turn.

#### Scenario: Agent adds a process trace
- **WHEN** Claude Code edits a Swift file and adds `(fix round 2)` to a comment
- **THEN** the hook reports the finding to the agent before its next step

### Requirement: Our own ordering is expressed in code
A comment SHALL NOT be the only thing that explains our own code's ordering, a flag, a guard, or
why two copies must agree. Such a case SHALL be expressed in code instead: a type, a name, a state
case or a test. Comments about the school's servers and Apple's platform behaviour remain allowed,
on a type whose name says what it handles. This rule is enforced in review.

#### Scenario: A comment explains a race
- **WHEN** a pull request adds a comment explaining that a write must check the login generation after an await
- **THEN** review asks for the write to go through the account session, which drops stale writes, and for the comment to be removed

#### Scenario: A comment explains a server's behaviour
- **WHEN** a comment explains that a lapsed school service redirects to the campus portal
- **THEN** it stays, on the type that detects that redirect
