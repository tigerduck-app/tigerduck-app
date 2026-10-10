import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct SSOLoginQueueTests {
    @MainActor
    private final class Tracker {
        var running = 0
        var mostAtOnce = 0
        var finished = 0
    }

    private func login(_ tracker: Tracker) async {
        await SSOLoginService.oneAtATime {
            tracker.running += 1
            tracker.mostAtOnce = max(tracker.mostAtOnce, tracker.running)
            try? await Task.sleep(for: .milliseconds(20))
            tracker.running -= 1
            tracker.finished += 1
        }
    }

    @Test("SSO logins started together run one after another")
    func loginsDoNotOverlap() async {
        let tracker = Tracker()
        async let first: Void = login(tracker)
        async let second: Void = login(tracker)
        async let third: Void = login(tracker)
        _ = await (first, second, third)
        #expect(tracker.mostAtOnce == 1)
        #expect(tracker.finished == 3)

        await login(tracker)
        #expect(tracker.finished == 4)
    }

    @Test("a login for an account that signed out sends nothing")
    func loginAfterSignOutStops() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let serviceURL = SettingsAPIStub.uniqueBaseURL()
        await #expect(throws: CancellationError.self) {
            try await SSOLoginService.ensureServiceLogin(
                session: URLSession(configuration: config),
                serviceURL: serviceURL,
                studentId: "B00000000",
                password: "unused",
                generation: NTUSTSessionManager.shared.generation &- 1
            )
        }
        #expect(SettingsAPIStub.requests(for: serviceURL).isEmpty)
    }
}
