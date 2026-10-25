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

    @Test("a launch sends the unregister a sign-out left unsent past onboarding, signed in only for another backend")
    func theLaunchRetriesOnlyPastOnboardingAndForAnotherAccount() {
        let here = URL(string: "https://api.example.test/v3")!
        let there = URL(string: "https://old.example.test/v3")!
        #expect(AppState.retriesDepartingUnregister(onboarded: true, signedIn: false, keptOn: here, backend: here))
        #expect(!AppState.retriesDepartingUnregister(onboarded: false, signedIn: false, keptOn: here, backend: here))
        #expect(!AppState.retriesDepartingUnregister(onboarded: true, signedIn: true, keptOn: here, backend: here))
        #expect(!AppState.retriesDepartingUnregister(
            onboarded: true, signedIn: true, keptOn: URL(string: "https://api.example.test/v3/")!, backend: here
        ))
        #expect(AppState.retriesDepartingUnregister(onboarded: true, signedIn: true, keptOn: there, backend: here))
        #expect(!AppState.retriesDepartingUnregister(onboarded: true, signedIn: false, keptOn: nil, backend: here))
    }

    @Test("the launch's retry of a kept unregister forgets no pages and leaves the delivered notifications")
    func theLaunchRetryClearsNothingOfAnAccount() async {
        let steps = Steps()
        let auth = AuthService(
            keychainHasCredentials: { false },
            notificationCenter: NotificationCenter(),
            schoolSignIn: { _, _ in false }
        )
        #if os(iOS)
        let center = DeliveredNotificationsStub([("reminder-1", "assignments")])
        auth.accountNotifications = center
        #endif
        auth.beginSignOutBackgroundTask = {
            await MainActor.run { steps.taken.append("begin") }
            return { await MainActor.run { steps.taken.append("end") } }
        }
        auth.forgetPages = { steps.taken.append("pages") }

        auth.startDepartingUnregisterRetry { steps.taken.append("retry") }
        await auth.departingUnregisterRetry?.value

        #expect(steps.taken == ["begin", "retry", "end"])
        #expect(auth.signOutCalls == nil)
        #if os(iOS)
        #expect(center.delivered.count == 1)
        #endif
    }
}
