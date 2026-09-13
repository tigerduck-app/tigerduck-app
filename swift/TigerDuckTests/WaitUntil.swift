import Foundation
import Testing

/// Polls `condition` until it holds or `timeout` passes, and records an issue
/// at the caller if it never does.
///
/// For state that settles a hop or a debounce window after whatever causes
/// it. A fixed sleep sized on a quiet machine is too short on a loaded CI
/// runner: the whole suite shares one main actor there, and CI runs have
/// shown it starved for 15 seconds and more at a stretch. Waiting for the
/// state itself is not timing-sensitive, so the timeout is generous. It only
/// bounds a real failure, and a passing test returns as soon as the state
/// settles.
///
/// The condition is checked once more after the deadline: after a long
/// stall the loop wakes past its deadline in the same breath as the work it
/// was waiting for, and giving up without looking would fail a test whose
/// state is already there.
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
