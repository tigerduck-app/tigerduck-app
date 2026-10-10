# Issue and pull request triage

How maintainers label issues and pull requests. Set a field only when its rule applies; most
issues need no label at all.

## Issues

| Field | Use |
|---|---|
| Type | One per issue. Bug: something that should work does not. Feature: new functionality or an improvement. Task: any other work, such as refactoring, documentation, CI, dependency updates or a release |
| Labels | Only those in the label table below whose rule applies |
| Priority | Bugs only. Urgent: a crash, data loss, or most people cannot use the app. High: a main feature is broken. Medium: there is a workaround. Low: cosmetic or minor |
| Effort, Start date, Target date | Not used |
| Assignees | Whoever starts the work |
| Milestone | Not used yet. To plan a release, open one per version (such as `2.4.0`) and add only the issues committed to it |
| Projects | Not used yet. For a board, create an organization project with auto-add, so issues join it without being picked by hand |
| Relationships | Split a large issue into sub-issues. Mark an issue as blocked by the issue or backend change it waits for. Close a duplicate with "Close as duplicate" |

The issue templates set the type: Bug for a bug report and Feature for a feature request.

## Pull requests

Pull requests have no type, so a label gives the kind:

- `bug`: fixes a bug
- `enhancement`: adds or improves a feature
- `documentation`: only changes documentation
- `dependencies`: a dependency update; Dependabot and Renovate add it

Other work, such as refactoring or CI, gets no kind label. Link the issue with `Closes #123` in
the description. Reviewers, milestone and projects are not set by hand; Greptile reviews every
pull request.

## Labels

| Label | When |
|---|---|
| `iPhone`, `iPad`, `macOS`, `watch` | The problem or change affects only that platform; leave them off when every platform is affected |
| `Android too` | The Android app needs the same fix or feature |
| `sync with Android` | The Android app already has this; bring it to the Apple apps |
| `language` | A missing or wrong translation, or unclear wording |
| `security` | Security hardening. Vulnerabilities are reported privately, not in issues |
| `question` | Waiting for more information from the reporter |
| `good first issue` | A small, well-defined task for a new contributor |
| `help wanted` | Maintainers would welcome outside help |

There are no `duplicate`, `invalid` or `wontfix` labels: close the issue as a duplicate or as
not planned instead.
