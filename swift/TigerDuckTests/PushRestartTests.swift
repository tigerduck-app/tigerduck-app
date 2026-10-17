import Foundation
import Testing
@testable import TigerDuck

/// The push stack across a sign-out. Its unregister drops the device's APNs tokens and stops the
/// token relay, which only a launch started again, so a sign-in in the same run got no pushes
/// (https://github.com/tigerduck-app/tigerduck-app/issues/469). The API client is a stand-in.
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

    /// The session a sign-out ended is kept until the server has its unregister
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/460).
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

    /// A first sign-in, as in onboarding: the launch starts the stack only once onboarding is done,
    /// so nothing reaches the backend before it.
    @Test func aFirstSignInStartsNothing() async {
        let push = Self.coordinator()

        push.refreshRegistrationAfterAuth()

        #expect(await !push.currentSnapshot().isStarted)
    }
}
