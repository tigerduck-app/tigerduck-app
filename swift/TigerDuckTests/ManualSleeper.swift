import Testing

/// The wait a test injects as a type's `sleep:` argument, as `{ _ in await sleeper.sleep() }`.
/// Each wait reports that it started and then parks until the test calls `fire()`, so a
/// debounce ends when the test says and not when a clock does.
actor ManualSleeper {
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var armings = 0

    /// One wait, parked until `fire()`.
    func sleep() async {
        armings += 1
        await withCheckedContinuation { sleepers.append($0) }
    }

    /// Returns once at least `count` waits have started. If they never do, it records an issue at
    /// the caller after `waitUntil`'s timeout and returns, so the test fails instead of hanging.
    func waitUntilArmed(atLeast count: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) async {
        try? await waitUntil({ armings >= count }, sourceLocation: sourceLocation)
    }

    /// Ends every wait in progress, as if its duration had passed.
    func fire() {
        let waiting = sleepers
        sleepers = []
        for sleeper in waiting { sleeper.resume() }
    }
}
