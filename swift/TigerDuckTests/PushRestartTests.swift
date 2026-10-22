import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct PushRestartTests {
    private static func coordinator(
        baseURL: URL = SettingsAPIStub.uniqueBaseURL(), authHeader: String? = nil
    ) -> PushCoordinator {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let client = PushAPIClient(
            baseURLProvider: { baseURL },
            session: URLSession(configuration: config),
            authHeaderProvider: { authHeader }
        )
        return PushCoordinator(identity: PushIdentity(uuid: "test-device"), apiClient: client)
    }

    @Test func aSignOutReportsWhetherTheServerHasItsUnregister() async {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let unregisterURL = baseURL.appendingPathComponent("devices/test-device")
        let push = Self.coordinator(baseURL: baseURL, authHeader: "Bearer A1")
        SettingsAPIStub.enqueue(.init(statusCode: 204, body: Data()), for: unregisterURL)
        push.enable()

        #expect(await push.disable())
        #expect(await !push.disable())
        #expect(SettingsAPIStub.requests(for: unregisterURL).count == 1)
    }

    @Test func aSignInAfterASignOutStartsPushAgain() async {
        let push = Self.coordinator()
        push.enable()
        await push.disable()
        #expect(await !push.currentSnapshot().isStarted)

        push.refreshRegistrationAfterAuth()

        #expect(await push.currentSnapshot().isStarted)
    }

    @Test func aFirstSignInStartsNothing() async {
        let push = Self.coordinator()

        push.refreshRegistrationAfterAuth()

        #expect(await !push.currentSnapshot().isStarted)
    }
}
