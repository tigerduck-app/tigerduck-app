# Spec Delta

## Purpose

Keep the pull-request test gate fast and trustworthy: skip the work a change cannot affect, keep
every required check reporting, and make test timing independent of the machine.

## ADDED Requirements

### Requirement: Documentation-only pull requests skip the Xcode legs
A pull request whose changed paths all match `*.md`, `docs/**`, `openspec/**`, `.claude/**`,
`.agents/**` or `.greptile/**` SHALL get a passing `unit-tests (phone)` and `unit-tests (watch)`
without compiling or running tests. Each skipped leg SHALL log that it skipped and why.

#### Scenario: Documentation only
- **WHEN** a pull request changes only `AGENTS.md` and files under `openspec/`
- **THEN** both unit-test legs pass without running xcodebuild, and the log says the leg skipped for a documentation-only change

#### Scenario: Mixed change
- **WHEN** a pull request changes a Markdown file and a Swift file
- **THEN** both legs build and test as before

#### Scenario: Workflow change
- **WHEN** a pull request changes anything under `.github/workflows/`
- **THEN** both legs build and test

### Requirement: Required checks never wait on skipped work
Skipping SHALL happen inside the jobs, so every check name a branch rule may require reports a
result on every pull request instead of staying pending.

#### Scenario: Branch rule requires the phone leg
- **WHEN** a documentation-only pull request is opened against `dev`
- **THEN** `unit-tests (phone)` reports success and the pull request can merge

### Requirement: SwiftMail tests run only when they can fail differently
On a pull request, the vendored SwiftMail job SHALL run `swift test` only when the pull request
changes `swift/Packages/SwiftMail/**` or `.github/workflows/tests.yaml`. On pushes to `dev` and
`main` it SHALL always run.

#### Scenario: App-only pull request
- **WHEN** a pull request changes only app sources
- **THEN** the SwiftMail job passes without running `swift test` and logs why

#### Scenario: Package change
- **WHEN** a pull request changes a file under `swift/Packages/SwiftMail/`
- **THEN** the SwiftMail job runs the package tests

### Requirement: Tests do not wait on the wall clock
A unit test SHALL NOT sleep for a fixed duration to wait for a debounce, timer or layout pass.
Code with a debounce or timer SHALL take an injectable clock or duration so tests advance time
themselves, and layout waits SHALL poll for the condition they need.

#### Scenario: Debounce on a loaded machine
- **WHEN** the Watch sync debounce test runs on a busy CI runner
- **THEN** it passes without real sleeping, and passes 20 runs in a row

#### Scenario: Searching for sleeps
- **WHEN** someone searches the test targets for `Task.sleep`, `Thread.sleep` and `usleep`
- **THEN** the only hits are inside fakes or cancelled placeholder tasks

### Requirement: Pure-logic suites run off the main actor
A test suite SHALL be `@MainActor` only when it uses an API isolated to the main actor.

#### Scenario: Suite without main-actor APIs
- **WHEN** a suite only exercises value types and nonisolated functions
- **THEN** it carries no `@MainActor` annotation

### Requirement: Speed changes ship with measurements
A CI or test change made for speed SHALL ship with timings from at least three warm runs with the
change and three without it: pull-request runs for a workflow change, local runs for a test
change. The numbers SHALL be in the pull request description, and a change that does not shorten
the step it targets SHALL be reverted before the merge.

#### Scenario: Workflow speed change
- **WHEN** the pull request changes the boot order to save time
- **THEN** its description lists the boot and test step times of three runs before and three after, and the change stays only if the after times are lower

#### Scenario: Test speed change
- **WHEN** the pull request removes `@MainActor` from test suites to save time
- **THEN** its description lists three local "ran for" times with the change and three without it, and the change stays only if the times with it are lower
