import Foundation

@MainActor
enum LibraryPasswordRetry {
    private(set) static var task: Task<Void, Never>?
    private static var misses = 0

    static func retryStoredPasswordWhenWaitEnds(
        signIn: @escaping @MainActor (String, String) async throws -> LibraryLoginData,
        retrySleep: @escaping @Sendable (Duration) async -> Void
    ) {
        misses = 0
        let now = Date()
        guard let retryAt = StoredPasswordBackoff.library.retryAt(now: now) else { return cancel() }
        start(after: max(0, retryAt.timeIntervalSince(now)), signIn: signIn, retrySleep: retrySleep)
    }

    private static func start(
        after wait: TimeInterval,
        signIn: @escaping @MainActor (String, String) async throws -> LibraryLoginData,
        retrySleep: @escaping @Sendable (Duration) async -> Void
    ) {
        cancel()
        task = AccountSession.library.task { librarySignIn in
            await retrySleep(.seconds(wait))
            guard !Task.isCancelled, librarySignIn.isCurrent else { return }
            guard LibraryService.storedPasswordPostIsDue(now: Date()) else {
                task = nil
                return retryStoredPasswordWhenWaitEnds(signIn: signIn, retrySleep: retrySleep)
            }
            let refusals = LibraryService.storedPasswordRefusals.count
            let signedIn = (try? await LibraryService.ensureToken(signIn: signIn, retrySleep: retrySleep)) != nil
            guard !Task.isCancelled else { return }
            task = nil
            guard !signedIn, librarySignIn.isCurrent, refusals > 0,
                  LibraryService.storedPasswordRefusals.count == refusals else { return }
            misses += 1
            start(
                after: StoredPasswordBackoff.retryDelay(afterRefusals: refusals + misses),
                signIn: signIn, retrySleep: retrySleep
            )
        }
    }

    static func cancel() {
        task?.cancel()
        task = nil
    }
}
