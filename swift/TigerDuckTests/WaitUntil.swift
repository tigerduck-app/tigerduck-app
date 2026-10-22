import Foundation
import Testing

func waitUntil(
    timeout: Duration = .seconds(60),
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    try await waitUntil(timeout: timeout, clock: ContinuousClock(), condition, sourceLocation: sourceLocation)
}

func waitUntil<C: Clock<Duration>>(
    timeout: Duration,
    clock: C,
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let step = Duration.milliseconds(5)
    var spent = Duration.zero
    while spent < timeout {
        if condition() { return }
        let start = clock.now
        try await clock.sleep(for: step)
        spent += max(step, start.duration(to: clock.now) / 10)
    }
    await Task.yield()
    if condition() { return }
    Issue.record("condition never became true within \(timeout)", sourceLocation: sourceLocation)
}
