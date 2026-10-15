#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

/// What a school sign-out leaves in Notification Center for whoever uses the phone next
/// (https://github.com/tigerduck-app/tigerduck-app/issues/564). The center is a stand-in, so the
/// test host's own notifications are left alone.
@MainActor
struct SignOutNotificationTests {
    @MainActor
    private final class Center: DeliveredNotificationCenter {
        var delivered: [(identifier: String, thread: String)]

        init(_ delivered: [(identifier: String, thread: String)]) {
            self.delivered = delivered
        }

        func deliveredNotificationThreads() async -> [(identifier: String, thread: String)] {
            delivered
        }

        func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
            delivered.removeAll { identifiers.contains($0.identifier) }
        }
    }

    @Test func aSignOutTakesTheAccountsRemindersAndBulletins() async {
        let center = Center([
            ("class-reminder", "course"),
            ("homework-reminder", "assignment"),
            ("bulletin", "other"),
            ("new-mail", MailConstants.notificationThread),
        ])

        await AuthService.removeAccountNotifications(from: center)

        // The mail account may be another student's, which the sign-out keeps.
        #expect(center.delivered.map(\.identifier) == ["new-mail"])
    }

    /// The backend can push to the account until the device's unregister, one of the sign-out's
    /// calls, lands.
    @Test func aSignOutClearsAtOnceAndAgainAfterItsCalls() async throws {
        let center = Center([("bulletin", "other")])
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

        auth.logout()
        try await waitUntil { center.delivered.isEmpty }
        await auth.startSignOutCalls { center.delivered.append(("class-reminder", "course")) }.value

        #expect(center.delivered.isEmpty)
    }
}
#endif
