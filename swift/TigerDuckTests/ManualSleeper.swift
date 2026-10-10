import Testing

/// The wait a test injects as a type's `sleep:` argument, as `{ await sleeper.sleep(for: $0) }`.
/// Each wait records the duration it was asked for and then parks until the test calls
/// `fire()`, so a debounce ends when the test says and not when a clock does, and the test can
/// still check the window the code asked for. Cancelling the waiting task ends its wait at once,
/// as it ends a real `Task.sleep`.
actor ManualSleeper {
    struct NeverArmed: Error {}

    private var sleepers: [Int: CheckedContinuation<Void, Never>] = [:]
    /// The duration of every wait so far, in the order the waits started.
    private(set) var requestedDurations: [Duration] = []

    /// How many waits have started.
    var armedCount: Int { requestedDurations.count }

    /// One wait for `duration`, parked until `fire()` or until its task is cancelled.
    func sleep(for duration: Duration) async {
        requestedDurations.append(duration)
        let id = requestedDurations.count
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { sleepers[id] = continuation }
            }
        } onCancel: {
            Task { await self.release(id) }
        }
    }

    /// Returns once at least `count` waits have started. If they never do, it records an issue at
    /// the caller after `waitUntil`'s timeout and throws, so the test stops instead of firing a
    /// wait that has not started and then hanging on it.
    func waitUntilArmed(atLeast count: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitUntil({ armedCount >= count }, sourceLocation: sourceLocation)
        guard armedCount >= count else { throw NeverArmed() }
    }

    /// Ends every wait in progress, as if its duration had passed.
    func fire() {
        let waiting = sleepers.values
        sleepers = [:]
        for sleeper in waiting { sleeper.resume() }
    }

    private func release(_ id: Int) {
        sleepers.removeValue(forKey: id)?.resume()
    }
}
