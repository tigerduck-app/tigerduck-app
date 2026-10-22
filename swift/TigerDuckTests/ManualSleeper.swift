import Testing

actor ManualSleeper {
    struct NeverArmed: Error {}

    private var sleepers: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var requestedDurations: [Duration] = []

    var armedCount: Int { requestedDurations.count }

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

    func waitUntilArmed(atLeast count: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitUntil({ armedCount >= count }, sourceLocation: sourceLocation)
        guard armedCount >= count else { throw NeverArmed() }
    }

    func fire() {
        let waiting = sleepers.values
        sleepers = [:]
        for sleeper in waiting { sleeper.resume() }
    }

    private func release(_ id: Int) {
        sleepers.removeValue(forKey: id)?.resume()
    }
}
