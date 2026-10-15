import Foundation
import Testing
@testable import TigerDuck

/// The push stack across a sign-out. Its unregister drops the device's APNs tokens and stops the
/// token relay, which only a launch started again, so a sign-in in the same run got no pushes
/// (https://github.com/tigerduck-app/tigerduck-app/issues/469). The API client is a stand-in.
@MainActor
struct PushRestartTests {
    private static func coordinator() -> PushCoordinator {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let client = PushAPIClient(
            baseURLProvider: { baseURL },
            session: URLSession(configuration: config),
            authHeaderProvider: { nil }
        )
        return PushCoordinator(identity: PushIdentity(uuid: "test-device"), apiClient: client)
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
