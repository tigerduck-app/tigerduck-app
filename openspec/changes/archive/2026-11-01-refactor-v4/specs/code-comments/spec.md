# Spec Delta

## ADDED Requirements

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

## MODIFIED Requirements

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
