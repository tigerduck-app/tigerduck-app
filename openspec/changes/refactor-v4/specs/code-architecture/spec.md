# Spec Delta

## Purpose

Keeps every shared rule of the Apple clients in one place that agents and people can find, keeps
types small enough to have one responsibility, and makes a second copy or an oversized type fail CI.

## ADDED Requirements

### Requirement: Shared rules have one listed home
`swift/TigerDuck/AGENTS.md` SHALL list each rule shared across features, one line each, with the
type and path that owns it. Code SHALL call the home instead of writing the rule again.

#### Scenario: An agent needs today's classes
- **WHEN** an agent writes code that needs the current or next class
- **THEN** the AGENTS.md line for "now and next" points it to the class timeline in TigerDuckCore, and it calls that

#### Scenario: A second copy
- **WHEN** a pull request constructs the Taipei time zone outside TigerDuckCore
- **THEN** `tools/check_architecture.py` fails and names the home to use

### Requirement: Rules without UI or I/O live in TigerDuckCore
Rules that need neither UI nor I/O and are used by more than one target SHALL live in the local
package `swift/Packages/TigerDuckCore`, linked by the app, Watch app, widgets, complication and
Live Activity extension. A target SHALL NOT keep its own copy of such a rule.

#### Scenario: The widget needs the class timeline
- **WHEN** the widget shows the next class
- **THEN** it converts its own course data to TigerDuckCore's input type and asks TigerDuckCore's timeline, with no widget-only copy of the rule

### Requirement: Types stay within a size budget
A type's own body, extensions in other files counted and nested types not, SHALL stay under 250
lines; a SwiftUI view under 200. A class or actor SHALL hold at most 10 stored instance properties.
A Swift file SHALL stay under 400 lines. An extension in another file SHALL add only a protocol
conformance.

#### Scenario: A type grows past the budget
- **WHEN** a pull request makes a type 260 lines long
- **THEN** `tools/check_architecture.py` fails with the type, its size and the budget

#### Scenario: A nested helper
- **WHEN** a type holds a nested type that serves only it
- **THEN** the nested type's lines do not count toward the outer type's budget

### Requirement: Layers are enforced
Code under `swift/TigerDuck/Features/` SHALL reach school, backend and persistence code only
through the stores and account sessions. Login-generation checks SHALL appear only under
`swift/TigerDuck/Account/`. `UserDefaults` SHALL be opened only under
`swift/TigerDuck/Persistence/`, apart from the extension targets' App Group readers. Code SHALL
wait for a state or a time only through the shared waiting primitives.

#### Scenario: A view model calls a school service
- **WHEN** a file under `Features/` names a type declared under `School/`
- **THEN** `tools/check_architecture.py` fails and points to the store to use

### Requirement: Each account has its own session
The school account, the library account and School Mail SHALL each have their own session scope.
Signing out of one SHALL leave the other accounts' data alone, and a result that arrives after its
account signed out SHALL be dropped.

#### Scenario: School sign-out keeps School Mail
- **WHEN** the user signs out of the school account
- **THEN** School Mail stays signed in and its cache is kept

#### Scenario: A reply lands after sign-out
- **WHEN** a school fetch started before sign-out returns afterwards
- **THEN** its result is dropped and nothing of the departed account is written

### Requirement: Sign-out clears every store in order
Signing out SHALL cancel the account's work, move its generation, clear every store the account
owns, and then start the network calls that need the departing session, in that order; a sign-in
SHALL wait for those calls. Clearing SHALL remove a store's files and keys by name, whether or not
the store was used in this process.

#### Scenario: Sign-out after a launch that never opened a feature
- **WHEN** the user signs out of the school account in a process that never loaded the imported class tables
- **THEN** the imported class table files are still deleted

#### Scenario: Sign-in right after a sign-out
- **WHEN** another student signs in while the departing device unregister is still running
- **THEN** the sign-in waits for it to finish

### Requirement: Nothing reads stored data before the first unlock
The app SHALL build its environment, sessions and stores only after protected data can be read,
so a launch before the first unlock after a restart never reads stored data as empty.

#### Scenario: Silent push before the first unlock
- **WHEN** a silent push launches the app before the device has been unlocked since a restart
- **THEN** no store is built, no stored credential is deleted, and the work runs once the device is unlocked

### Requirement: Fetched data is applied to the current state
A fetch SHALL apply its result to a store's state at the time the result arrives, never write back
a copy it read before an `await`. A result fetched with inputs that have since changed (the
account, a switch, the display language) SHALL be dropped.

#### Scenario: An add during a refresh
- **WHEN** the user adds a course while the user-added course refresh is looking courses up
- **THEN** the refresh updates the details of the courses it looked up, and the added course stays

#### Scenario: A language change during a fetch
- **WHEN** the user changes the app language while a course fetch runs
- **THEN** the fetch's result is dropped and a fetch in the new language runs
