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

    @Test("a sign-out forgets the school's pages within its calls, which a sign-in waits for, before the rest")
    func theCallsForgetTheSchoolPages() async {
        let steps = Steps()
        let auth = AuthService(
            keychainHasCredentials: { false },
            notificationCenter: NotificationCenter(),
            schoolSignIn: { _, _ in false }
        )
        #if os(iOS)
        auth.accountNotifications = DeliveredNotificationsStub()
        #endif
        auth.beginSignOutBackgroundTask = { {} }
        auth.forgetPages = { steps.taken.append("pages") }

        let calls = auth.startSignOutCalls { steps.taken.append("calls") }

        #expect(auth.signOutCalls == calls)
        await calls.value
        #expect(steps.taken == ["pages", "calls"])
    }

    @Test("a launch sends the unregister a sign-out left unsent only past onboarding and signed out")
    func theLaunchRetriesOnlyPastOnboardingAndSignedOut() {
        #expect(AppState.retriesDepartingUnregister(onboarded: true, signedIn: false, sessionKept: true))
        #expect(!AppState.retriesDepartingUnregister(onboarded: false, signedIn: false, sessionKept: true))
        #expect(!AppState.retriesDepartingUnregister(onboarded: true, signedIn: true, sessionKept: true))
        #expect(!AppState.retriesDepartingUnregister(onboarded: true, signedIn: false, sessionKept: false))
    }
}
