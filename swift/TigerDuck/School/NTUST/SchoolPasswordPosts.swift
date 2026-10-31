import Foundation

/// The automatic posts of the stored school password: their refusal count and wait, and the lock
/// that runs them one at a time.
nonisolated enum SchoolPasswordPosts {
    static var storedPasswordRefusals: (count: Int, last: Date?) {
        get { StoredPasswordBackoff.ntust.refusals }
        set { StoredPasswordBackoff.ntust.refusals = newValue }
    }

    static let storedPasswordPostWaits = Notification.Name("TigerDuck.storedPasswordPostWaits")
    static let storedPasswordRetryAtKey = "retryAt"

    static func storedPasswordRetryAt(now: Date = Date()) -> Date? {
        StoredPasswordBackoff.ntust.retryAt(now: now)
    }

    static func storedPasswordPostMustWait(now: Date = Date()) -> Bool {
        guard let retryAt = storedPasswordRetryAt(now: now), retryAt > now else { return false }
        announceStoredPasswordWait(until: retryAt)
        return true
    }

    static func noteStoredPasswordRefused(at now: Date = Date()) {
        announceStoredPasswordWait(until: StoredPasswordBackoff.ntust.noteRefused(at: now))
    }

    private static func announceStoredPasswordWait(until retryAt: Date) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: storedPasswordPostWaits, object: nil, userInfo: [storedPasswordRetryAtKey: retryAt]
            )
        }
    }

    static func forgetStoredPasswordRefusals() {
        StoredPasswordBackoff.ntust.forget()
    }

    private static let storedPasswordPosts = AsyncSerialLock()

    static func storedPasswordPostsWaiting() async -> Int {
        await storedPasswordPosts.waiterCount
    }

    /// Runs `body` alone among the automatic posts of the stored password: the SSO sign-ins here
    /// and `MoodleTokenService`'s token renewal. Two at once would each post a password the school
    /// refused before either counted the refusal, and the school counts both toward the lockout.
    /// `body` checks ``storedPasswordPostMustWait(now:)``, posts, reads the answer and counts a
    /// refusal before it returns. A sign-in the user typed posts what was typed, so it does not wait.
    nonisolated(nonsending) static func postingStoredPassword<T>(
        _ body: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        await storedPasswordPosts.acquire()
        do {
            let result = try await body()
            await storedPasswordPosts.release()
            return result
        } catch {
            await storedPasswordPosts.release()
            throw error
        }
    }
}
