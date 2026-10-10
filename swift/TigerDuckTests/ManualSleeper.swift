import Testing

/// The wait a test injects as a type's `sleep:` argument, as `{ await sleeper.sleep(for: $0) }`.
/// Each wait records the duration it was asked for and then parks until the test calls
/// `fire()`, so a debounce ends when the test says and not when a clock does, and the test can
/// still check the window the code asked for.
actor ManualSleeper {
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    /// The duration of every wait so far, in the order the waits started.
    private(set) var requestedDurations: [Duration] = []

    /// One wait for `duration`, parked until `fire()`.
    func sleep(for duration: Duration) async {
        requestedDurations.append(duration)
        await withCheckedContinuation { sleepers.append($0) }
    }

    /// Returns once at least `count` waits have started. If they never do, it records an issue at
    /// the caller after `waitUntil`'s timeout and returns, so the test fails instead of hanging.
    func waitUntilArmed(atLeast count: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) async {
        try? await waitUntil({ requestedDurations.count >= count }, sourceLocation: sourceLocation)
    }

    /// Ends every wait in progress, as if its duration had passed.
    func fire() {
        let waiting = sleepers
        sleepers = []
        for sleeper in waiting { sleeper.resume() }
    }
}
