import Foundation
import Testing

/// Polls `condition` until it holds or `timeout` passes, and records an issue
/// at the caller if it never does.
///
/// For state that settles a hop or a debounce window after its cause. A fixed
/// sleep sized on a quiet machine is too short on a loaded CI runner, where the
/// suite's shared main actor has starved for 15 seconds and more. The generous
/// timeout only bounds a real failure. The last check after the deadline covers
/// a loop that wakes late together with the work it was waiting for.
func waitUntil(
    timeout: Duration = .seconds(60),
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    await Task.yield()
    if condition() { return }
    Issue.record("condition never became true within \(timeout)", sourceLocation: sourceLocation)
}
