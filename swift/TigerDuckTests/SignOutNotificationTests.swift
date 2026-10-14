#if os(iOS)
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

        await AppState.removeAccountNotifications(from: center)

        // The mail account may be another student's, which the sign-out keeps.
        #expect(center.delivered.map(\.identifier) == ["new-mail"])
    }
}
#endif
