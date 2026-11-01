import Foundation

nonisolated enum SchoolPasswordPosts {
    static var storedPasswordRefusals: (count: Int, last: Date?) { StoredPasswordLockoutBackoff.ntust.refusals }

    static func setStoredPasswordRefusals(_ refusals: (count: Int, last: Date?), for signIn: SignIn) {
        StoredPasswordLockoutBackoff.ntust.setRefusals(refusals, for: signIn)
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

    static func noteStoredPasswordRefused(at now: Date = Date(), for signIn: SignIn) {
        announceStoredPasswordWait(until: StoredPasswordLockoutBackoff.ntust.recordRefusalAndNextPost(at: now, for: signIn))
    }

    private static func announceStoredPasswordWait(until retryAt: Date) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: storedPasswordPostWaits, object: nil, userInfo: [storedPasswordRetryAtKey: retryAt]
            )
        }
    }

    static func forgetStoredPasswordRefusals(for signIn: SignIn) {
        StoredPasswordLockoutBackoff.ntust.setRefusals((0, nil), for: signIn)
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
