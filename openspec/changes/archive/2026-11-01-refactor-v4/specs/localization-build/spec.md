# Spec Delta

## Purpose

The Apple clients' localized strings come from `app-translation/source/` at build time, so no
generated localization file is tracked in git and a build cannot ship without its strings.

## ADDED Requirements

### Requirement: Localizations are generated at build time
Each Apple target that shows localized text SHALL generate its `.lproj` folders from
`app-translation/source/` during its build and copy them into its own bundle. Neither this
repository nor `app-translation` SHALL track generated Apple localization files.

#### Scenario: Clean clone
- **WHEN** a clean clone with submodules is built in Xcode, by `xcodebuild` or by Xcode Cloud
- **THEN** the app and each extension bundle hold every locale's `Localizable.strings` and `InfoPlist.strings`, and `git status` shows nothing generated

#### Scenario: A translation changes
- **WHEN** `app-translation/source/de.json` changes and the submodule pin moves
- **THEN** the next build ships the new German strings without any other commit

### Requirement: A build without localizations fails
The build SHALL fail when the generator or `python3` is missing, or when fewer than 60 locales are
produced.

#### Scenario: Submodule not checked out
- **WHEN** the build runs without the `app-translation` submodule
- **THEN** it fails with a message naming the submodule, instead of shipping raw string keys

### Requirement: Key checks read the source
`tools/localization/check_keys.py` SHALL compare the keys the app uses with
`app-translation/source/en.json`.

#### Scenario: A new key without a translation
- **WHEN** the app adds a key that `source/en.json` lacks
- **THEN** the check fails and names the key
