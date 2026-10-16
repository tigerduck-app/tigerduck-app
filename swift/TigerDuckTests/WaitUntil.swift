import Foundation
import Testing

/// Polls `condition` until it holds or `timeout` passes, and records an issue
/// at the caller if it never does.
///
/// For state that settles a hop or a debounce window after its cause. On a loaded CI runner the
/// suite's shared main actor starves for a minute and more, holding back this loop and the work
/// it waits for alike, so a wake late past its sleep counts a tenth of its length: a starved run
/// gets up to ten times `timeout`. The last check covers work that lands with the final wake.
func waitUntil(
    timeout: Duration = .seconds(60),
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    try await waitUntil(timeout: timeout, clock: ContinuousClock(), condition, sourceLocation: sourceLocation)
}

/// ``waitUntil(timeout:_:sourceLocation:)`` on `clock`, which a test of the polling sets.
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
