// The calls a sign-out still sends as the account that signed out, and the launch that sends its
// unregister again when it did not land (https://github.com/tigerduck-app/tigerduck-app/issues/460).
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

    /// Signed in, that account's backend sign-in drops what the retry would send: run beside it,
    /// the retry's unregister could revoke the session the sign-in starts.
    @Test("a launch sends the unregister a sign-out left unsent only past onboarding and signed out")
    func theLaunchRetriesOnlyPastOnboardingAndSignedOut() {
        #expect(AppState.retriesDepartingUnregister(onboarded: true, signedIn: false, sessionKept: true))
        #expect(!AppState.retriesDepartingUnregister(onboarded: false, signedIn: false, sessionKept: true))
        #expect(!AppState.retriesDepartingUnregister(onboarded: true, signedIn: true, sessionKept: true))
        #expect(!AppState.retriesDepartingUnregister(onboarded: true, signedIn: false, sessionKept: false))
    }
}
