---
name: writing-tests
description: Use when writing or changing a TigerDuck unit test, or when a test is flaky, failing on CI and passing on a rerun. Covers parallel suites, a busy main actor, on-screen tests, dates, the test host, waiting and fakes.
---

# Writing tests

CI runs the phone tests in parallel on a small runner, so a test that passes alone can fail
there. Each test owns its state, leaves the main actor free and waits on a condition.

## Own the state

Swift Testing runs every suite at once. `.serialized` orders the tests of one suite only, and
`@MainActor` lets tests interleave at each `await`, so state another suite can reach is shared
whatever the attributes say.

- Process-wide state the code keeps (a `static var`, a singleton) becomes an instance the code
  takes as a parameter, defaulting to the app's: `AppServiceBridge.sharedRound(rounds:)` takes
  `AssignmentRounds.shared`, and each test passes its own.
- A test that needs the real `UserDefaults` runs inside `withExclusiveRealDefaults`.
- Ids, keys and stub URLs are unique per test: random ids, `SettingsAPIStub.uniqueBaseURL()`.

## Keep the main actor free

A test holding the main actor stalls every test waiting on it, and a minute's hold fails
unrelated tests with "Time limit was exceeded".

- Slow synchronous work (Vision, image or PDF decoding, a large regex) runs in
  `try await onGlobalQueue { ... }`.
- A test that holds the main actor on purpose polls; a semaphore wait there is a priority
  inversion the Thread Performance Checker stalls the whole process to report.
- A suite that calls main-actor app API is `@MainActor` as a whole.
- A test that makes a window key or brings up the keyboard, a view service, accessibility or
  WebKit goes in `on_screen_tests` in `.github/workflows/tests.yaml`. On a just-booted simulator
  such a call can hold the main thread for a minute, so CI runs those after the rest, one at a
  time.

## Wait on a condition

- `waitUntil { ... }` for state that arrives later, with its 60-second default, which only
  bounds a real failure.
- `ManualSleeper` or an injected clock for code that sleeps; the test fires it.
- Callers that must reach a point first count themselves there, as `SharedAssignmentRoundTests`
  does with `entered`, and the test waits for the count.
- A deadline the code enforces gets a limit a starved main actor still meets; the test checks
  the order of events.
- A `.timeLimit` on a main-actor test is at least five minutes: on CI such tests have waited
  over a minute for their turn.
- An on-screen action that also scrolls or animates (clearing a search field scrolls the list
  back to it) can take the view the test watches off screen first. Set the scene up so the
  motion cannot change what is asserted, for example a window tall enough that nothing scrolls.

## The test environment

- `SchoolNetworkGuard` fails a test that reaches the school, Moodle or the library; give that
  seam a fake, such as a `URLProtocol` stub.
- The host app shows an empty scene (`TigerDuckLauncher` in `App/TigerDuckApp.swift`), so
  nothing from `TigerDuckApp` runs: a test installs the hooks it needs itself, as
  `LiveMailClientTests` does with `SchoolMailCharsetHook.install()`.
- CI runs in UTC: build dates in the Taipei zone (`TaipeiTime.calendar`), not the device's.

## Reading a flaky CI run

- Different tests fail on each rerun: shared state. Find what the failing tests share, a
  `static`, a Defaults key, a singleton.
- "Time limit was exceeded", or tests that take milliseconds locally running for a minute: a
  main-actor hold. Find the long test in the log over the same span.
- Before pushing, run the touched suites and then the whole phone target; one suite alone
  rarely shows either.
