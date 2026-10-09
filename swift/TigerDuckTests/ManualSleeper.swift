/// The wait a test injects as a type's `sleep:` argument, as `{ _ in await sleeper.sleep() }`.
/// Each wait reports that it started and then parks until the test calls `fire()`, so a
/// debounce ends when the test says and not when a clock does.
actor ManualSleeper {
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var armings = 0
    private var armWaiters: [CheckedContinuation<Void, Never>] = []

    /// One wait, parked until `fire()`.
    func sleep() async {
        armings += 1
        for waiter in armWaiters { waiter.resume() }
        armWaiters = []
        await withCheckedContinuation { sleepers.append($0) }
    }

    /// Returns once at least `count` waits have started.
    func waitUntilArmed(atLeast count: Int = 1) async {
        while armings < count {
            await withCheckedContinuation { armWaiters.append($0) }
        }
    }

    /// Ends every wait in progress, as if its duration had passed.
    func fire() {
        let waiting = sleepers
        sleepers = []
        for sleeper in waiting { sleeper.resume() }
    }
}
