# ci-test-gate Specification

## Purpose
Keep the pull-request test gate fast and trustworthy: skip the work a change cannot affect, keep
every required check reporting, and make test timing independent of the machine.

## Requirements

### Requirement: Documentation-only changes skip the Xcode legs
A pull request or a push to `dev` or `main` whose changed paths all match `*.md`, `docs/**`,
`openspec/**`, `api-poc/**`, `.claude/**`, `.agents/**`, `.greptile/**`,
`.github/ISSUE_TEMPLATE/**` or `LICENSE*` SHALL get a passing `unit-tests (phone)`,
`unit-tests (watch)` and `macOS build` without compiling or running tests. Each skipped leg SHALL
log that it skipped and why. A push SHALL be compared with the commit it replaced, not only its
last commit.

#### Scenario: Documentation only
- **WHEN** a pull request changes only `AGENTS.md` and files under `openspec/`
- **THEN** both unit-test legs pass without running xcodebuild, and the log says the leg skipped for a documentation-only change

#### Scenario: Mixed change
- **WHEN** a pull request changes a Markdown file and a Swift file
- **THEN** both legs build and test as before

#### Scenario: Workflow change
- **WHEN** a pull request changes anything under `.github/workflows/`
- **THEN** both legs build and test

#### Scenario: Documentation commit after a code commit
- **WHEN** one push to `dev` carries a Swift change and then a Markdown change
- **THEN** the push builds

### Requirement: Pushes build without testing
A push to `dev` or `main` SHALL build each Xcode leg and the macOS app, to save the caches pull
requests start from, and SHALL NOT run the tests the pull request already ran.

#### Scenario: A pull request merges into dev
- **WHEN** a pull request that changed Swift code merges into `dev`
- **THEN** the push run builds and saves the caches, and runs no tests

### Requirement: Required checks never wait on skipped work
Skipping SHALL happen inside the jobs, so every check name a branch rule may require reports a
result on every pull request instead of staying pending.

#### Scenario: Branch rule requires the phone leg
- **WHEN** a documentation-only pull request is opened against `dev`
- **THEN** `unit-tests (phone)` reports success and the pull request can merge

### Requirement: SwiftMail tests run only when they can fail differently
On a pull request, the vendored SwiftMail job SHALL run `swift test` only when the pull request
changes `swift/Packages/SwiftMail/**` or `.github/workflows/tests.yaml`. Pushes to `dev` and
`main` SHALL NOT run it.

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
- **THEN** the only hits are inside fakes, cancelled placeholder tasks and loops that poll for a condition

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

### Requirement: Architecture and account-state checks run on every pull request
Every pull request to `main` or `dev` SHALL run `tools/check_architecture.py` and
`tools/check_account_state.py`, and SHALL fail when either reports a finding.

#### Scenario: A store without a sign-out row
- **WHEN** a pull request declares a new cache file of the school account and adds no row to `docs/account-state.md`
- **THEN** the account-state check fails

### Requirement: TigerDuckCore tests run only when they can fail differently
A pull request to `main` or `dev` SHALL run `swift test` for `swift/Packages/TigerDuckCore` only
when it changes `swift/Packages/TigerDuckCore/**` or `.github/workflows/tests.yaml`. Pushes to
`dev` and `main` SHALL NOT run it.

#### Scenario: A change to a shared rule
- **WHEN** a pull request changes the class timeline in TigerDuckCore
- **THEN** the package's tests run on that pull request

#### Scenario: App-only pull request
- **WHEN** a pull request changes only app sources
- **THEN** the TigerDuckCore job passes without running `swift test` and logs why

### Requirement: The macOS source lists follow one source
The macOS source lists in `project.pbxproj` SHALL equal every app-target Swift file minus
`tools/macos-excluded-sources.txt`, and app-target Swift files SHALL have unique base names.
`tools/check_macos_sources.py --write` regenerates the lists; CI fails when they drift.

#### Scenario: A split adds files
- **WHEN** a pull request splits a type into three new files and runs `--write`
- **THEN** the lists include the new files and CI passes without hand edits
