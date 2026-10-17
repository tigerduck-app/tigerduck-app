// The calls a sign-out still sends as the account that signed out
// (https://github.com/tigerduck-app/tigerduck-app/issues/460).
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct SignOutCallsTests {
    @MainActor
    private final class Steps {
        var taken: [String] = []
    }

    @Test("a sign-out's calls run inside a background task, which ends once they have")
    func theCallsRunInABackgroundTask() async {
        let steps = Steps()
        let auth = AuthService(
            keychainHasCredentials: { false },
            notificationCenter: NotificationCenter(),
            schoolSignIn: { _, _ in false }
        )
        #if os(iOS)
        auth.accountNotifications = DeliveredNotificationsStub()
        #endif
        auth.beginSignOutBackgroundTask = {
            await MainActor.run { steps.taken.append("begin") }
            return { await MainActor.run { steps.taken.append("end") } }
        }

        await auth.startSignOutCalls { steps.taken.append("calls") }.value

        #expect(steps.taken == ["begin", "calls", "end"])
    }
}
