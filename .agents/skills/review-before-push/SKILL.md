---
name: review-before-push
description: Use before pushing a branch, every time, and when briefing a worker or starting a reviewer. Reviews the change for reuse across the whole project, every path into the state it touches, stored data, iOS 18/26/27 and CI, security, comments and docs, so review bots and CI find nothing new.
---

# Review before push

The bar: Greptile, Codex and CI find nothing this review could have found. A fix commit pushed
after review is a miss of this file; the same pull request adds the check that would have caught
it, under the step it belongs to.

Work through the steps in order on the whole diff (`git diff origin/dev...HEAD`). Each step ends
with evidence: an `rg` result, a test name that fails on the old code, a run's result line.

## 1. Inventory

List every concept the diff introduces, one line each: a type, a function, a cache or store, a
parser or matcher, a comparison or ordering, a request with its caching, a UI pattern.

## 2. Reuse

For each line of the inventory, search the whole repository (`swift/`, `swift/Shared/`,
`swift/Packages/`, the tests, `tools/`) by name, by the API it calls and by its key literals.

- The project has one: use it.
- It has one that almost fits: extend it.
- It has several: extract one shared implementation, move every caller onto it, delete the rest.

A second implementation of something the project already does is a defect, as is a new copy
beside existing duplicates. A conditional GET with an ETag goes through `ConditionalGet`
(`BackendClient.revalidate` for the backend). Term ordering lives in `AcademicTerm`; host names
are normalized by `TLSPinMatcher.hostName`.

## 3. Every path into the state

For each state the diff writes, list every other way to reach it and give each one a test that
fails without the change:

- sign-out or an account switch while an `await` is pending
- the sync switch turned off or on mid-flight
- a retry and a duplicate submit
- a second cache of the same data (another language, a fallback)
- a background refresh, a relaunch, the Watch, widgets and macOS
- a return to the foreground: a refresh added to the first load runs there too
- a write that failed: it is sent again without waiting for the server's revision to move

After every `await` that precedes a write, check `signIn.isCurrent` again before writing
(`docs/decisions/0029-account-bound-writes.md`). A late result for an old sign-in writes nothing.

## 4. Stored data and every caller

- A change in what stored data means or how it is shaped also reaches the copies already
  stored: `Defaults`, files, Keychain, caches still inside their freshness window, synced
  server rows. Test decoding a store the previous release wrote, and Keychain reads with the
  phone locked. One-time upgrade code goes in `swift/TigerDuck/Migrations/`.
- `rg` the old function, key, comparison or literal, and change every call site.

## 5. Platforms and CI

- Run the touched on-screen and UIKit-bridged suites on an iOS 26 simulator and an iOS 27 one
  before pushing. CI's phone job runs iOS 27.0 only, and its iOS 18 job runs only the search
  suites; where iOS 26 or iOS 18 behavior is not run, say why in the pull request.
- Tests follow the `writing-tests` skill. A test that starts a scroll or an animation waits for
  the outcome it asserts, not for the motion to end.
- A CI job, checker or script change is tried against its bypasses: a renamed or commented-out
  target, a non-ASCII path, a docs-only commit pushed after a code commit. A new macOS job uses
  the Xcode the phone job uses, checked against the runner image's README.

## 6. Security

Required when the diff touches URLs, hosts, credentials, tokens, cookies, TLS, sign-in, files or
a parser of outside input:

- Normalize host names with `TLSPinMatcher.hostName` everywhere a host is compared.
- Choose an allowlist over a denylist.
- Feed each parser and loop empty, oversized and hostile input.
- A time or date read from parts checks each part's range before combining them.
- Follow each credential: it reaches only the origin it belongs to.
- Then an adversarial reviewer, read-only, starting from the diff without the author's account.

## 7. Rules, comments, docs and UI

- The nearest `AGENTS.md` files, for example: no new responsibility on `AppState`; upgrade code
  only in `Migrations/`.
- Comments: run `python3 tools/check_comments.py check --base origin/dev`, then reread each new
  comment. It keeps a reason the code cannot state. Delete a comment that repeats the code,
  tells the history, names an earlier build or cites a path a reader cannot open.
- `rg` the changed behavior's words in `openspec/`, `docs/` and `MIGRATE.md`, and update stale
  text.
- A doc, skill or comment names only files, tests, jobs and behavior that exist on the base
  branch or in this diff, never ones only another open branch has; check each with
  `git grep ... origin/dev` or the diff.
- UI: 375 pt wide, the largest Dynamic Type, dark mode, and the VoiceOver label and state of each
  new control.

## Done when

Every step has its evidence for this diff, and the reviewer's report has no Critical or High
finding. The pull request body says what was not run and why.
