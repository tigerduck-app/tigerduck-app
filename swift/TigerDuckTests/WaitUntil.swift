import Foundation
import Testing

/// Polls `condition` until it holds or `timeout` passes, and records an issue
/// at the caller if it never does.
///
/// For state that settles a hop or a debounce window after whatever causes
/// it. A fixed sleep sized on a quiet machine is too short on a loaded CI
/// runner, where the whole suite shares one main actor; waiting for the state
/// itself is not. The timeout only bounds a real failure.
func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("condition never became true within \(timeout)", sourceLocation: sourceLocation)
}
