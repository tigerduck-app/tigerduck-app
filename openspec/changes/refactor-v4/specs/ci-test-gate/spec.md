# Spec Delta

## ADDED Requirements

### Requirement: Architecture and account-state checks run on every pull request
Every pull request to `main` or `dev` SHALL run `tools/check_architecture.py` and
`tools/check_account_state.py`, and SHALL fail when either reports a finding.

#### Scenario: A store without a sign-out row
- **WHEN** a pull request declares a new cache file of the school account and adds no row to `docs/account-state.md`
- **THEN** the account-state check fails

### Requirement: TigerDuckCore tests run on every pull request
Every pull request to `main` or `dev` SHALL run `swift test` for `swift/Packages/TigerDuckCore`.

#### Scenario: A change to a shared rule
- **WHEN** a pull request changes the class timeline in TigerDuckCore
- **THEN** the package's tests run on that pull request

### Requirement: The macOS source lists follow one source
The macOS source lists in `project.pbxproj` SHALL equal every app-target Swift file minus
`tools/macos-excluded-sources.txt`, and app-target Swift files SHALL have unique base names.
`tools/check_macos_sources.py --write` regenerates the lists; CI fails when they drift.

#### Scenario: A split adds files
- **WHEN** a pull request splits a type into three new files and runs `--write`
- **THEN** the lists include the new files and CI passes without hand edits
