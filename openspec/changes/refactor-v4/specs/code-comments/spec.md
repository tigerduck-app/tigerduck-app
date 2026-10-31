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
