import Foundation

nonisolated enum SchoolPasswordPosts {
    static var storedPasswordRefusals: (count: Int, last: Date?) {
        get { StoredPasswordLockoutBackoff.ntust.refusals }
        set { StoredPasswordLockoutBackoff.ntust.refusals = newValue }
    }

    static let storedPasswordPostWaits = Notification.Name("TigerDuck.storedPasswordPostWaits")
    static let storedPasswordRetryAtKey = "retryAt"

    static func storedPasswordRetryAt(now: Date = Date()) -> Date? {
        StoredPasswordLockoutBackoff.ntust.retryAt(now: now)
    }

    static func storedPasswordPostMustWait(now: Date = Date()) -> Bool {
        guard let retryAt = storedPasswordRetryAt(now: now), retryAt > now else { return false }
        announceStoredPasswordWait(until: retryAt)
        return true
    }

    static func noteStoredPasswordRefused(at now: Date = Date()) {
        announceStoredPasswordWait(until: StoredPasswordLockoutBackoff.ntust.recordRefusalAndNextPost(at: now))
    }

    private static func announceStoredPasswordWait(until retryAt: Date) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: storedPasswordPostWaits, object: nil, userInfo: [storedPasswordRetryAtKey: retryAt]
            )
        }
    }

    static func forgetStoredPasswordRefusals() {
        StoredPasswordLockoutBackoff.ntust.forget()
    }

    private static let storedPasswordPosts = AsyncSerialLock()

    static func storedPasswordPostsWaiting() async -> Int {
        await storedPasswordPosts.waiterCount
    }

    /// Two automatic posts at once would each post a password the school refused before either
    /// counted the refusal, and the school counts both toward the lockout.
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
