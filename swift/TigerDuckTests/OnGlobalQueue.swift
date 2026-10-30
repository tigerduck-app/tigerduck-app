import Foundation

/// Runs slow synchronous work, such as Vision, on a GCD thread while the caller awaits. Such work
/// can take a minute on a CI runner: on the main actor it stalls every test waiting there, and in a
/// detached task it holds one of the cooperative pool's threads, a third of a runner's
/// (https://github.com/tigerduck-app/tigerduck-app/issues/530).
func onGlobalQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result(catching: work))
        }
    }
}
