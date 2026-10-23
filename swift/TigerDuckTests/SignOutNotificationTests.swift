#if os(iOS)
import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct SignOutNotificationTests {
    @Test func aSignOutTakesTheAccountsRemindersAndBulletins() async {
        let center = DeliveredNotificationsStub([
            ("class-reminder", "course"),
            ("homework-reminder", "assignment"),
            ("bulletin", "other"),
            ("new-mail", MailConstants.notificationThread),
        ])

        await AuthService.removeAccountNotifications(from: center)

        #expect(center.delivered.map(\.identifier) == ["new-mail"])
    }

    @Test func aSignOutDropsTheSchoolPagesTheURLCacheKept() async throws {
        let cache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)
        let url = try #require(URL(string: "https://stuinfosys.ntust.edu.tw/StuScoreQueryServ/StuScoreQuery"))
        let request = URLRequest(url: url)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Cache-Control": "max-age=600", "Content-Type": "text/html"]
        ))
        cache.storeCachedResponse(CachedURLResponse(response: response, data: Data("<p>B11399001</p>".utf8)), for: request)
        try #require(cache.cachedResponse(for: request) != nil)

        await AuthService.forgetSchoolPages(cache: cache)

        #expect(cache.cachedResponse(for: request) == nil)
    }

    @Test func aSignOutClearsAtOnceAndAgainAfterItsCalls() async throws {
        let center = DeliveredNotificationsStub([("bulletin", "other")])
        let auth = AuthService(
            keychainHasCredentials: { false },
            notificationCenter: NotificationCenter(),
            moodleTokens: MoodleTokenService(
                storedCredentials: { nil }, tokens: .init(load: { nil }, save: { _ in }, drop: {}),
                harvest: { _, _ in throw CancellationError() }
            ),
            schoolSignIn: { _, _ in false },
            endSchoolSession: { _ in }
        )
        auth.accountNotifications = center

        try await withExclusiveRealDefaults {
            let saved = Defaults[.ntustCredentialsPresent]
            defer { Defaults[.ntustCredentialsPresent] = saved }
            try await SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) {
                auth.logout()
                try await waitUntil { center.delivered.isEmpty }
                await auth.startSignOutCalls { center.delivered.append(("class-reminder", "course")) }.value
            }
        }

        #expect(center.delivered.isEmpty)
    }
}

@MainActor
final class DeliveredNotificationsStub: DeliveredNotificationCenter {
    var delivered: [(identifier: String, thread: String)]

    init(_ delivered: [(identifier: String, thread: String)] = []) {
        self.delivered = delivered
    }

    func deliveredNotificationThreads() async -> [(identifier: String, thread: String)] {
        delivered
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        delivered.removeAll { identifiers.contains($0.identifier) }
    }
}
#endif
