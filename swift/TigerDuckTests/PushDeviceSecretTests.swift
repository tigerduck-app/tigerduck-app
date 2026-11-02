import Defaults
import Foundation
import Testing
@testable import TigerDuck

/// The device secret on the requests about this device's anonymous registration.
@Suite("Device secret on device requests")
struct PushDeviceSecretTests {
    private static let secret = String(repeating: "s", count: 43)

    private static func requests(_ identity: PushIdentity, baseURL: URL, signedIn: Bool = false) -> PushDeviceRequests {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return PushDeviceRequests(
            identity: identity,
            apiClient: PushAPIClient(
                baseURLProvider: { baseURL },
                session: URLSession(configuration: config),
                authHeaderProvider: { signedIn ? "Bearer test" : nil }
            ),
            signIns: testSignIns,
            bundleId: "org.ntust.app.TigerDuck",
            attrsType: "TigerDuckActivityAttributes",
            apnsEnv: "development",
            deviceClass: "iphone"
        )
    }

    private static func announceURL(_ baseURL: URL) -> URL { baseURL.appendingPathComponent("devices/anonymous") }
    private static func registerURL(_ baseURL: URL) -> URL { baseURL.appendingPathComponent("devices/register") }

    private static func answer(_ url: URL, status: Int = 200, body: String = "{}") {
        SettingsAPIStub.enqueue(.init(statusCode: status, body: Data(body.utf8)), for: url)
    }

    private static func sentBodies(to url: URL) throws -> [[String: Any]] {
        try SettingsAPIStub.requests(for: url).map { request in
            let body = try #require(SettingsAPIStub.bodyData(from: request))
            return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
    }

    private static func withServerPushOptOut(_ body: () async throws -> Void) async rethrows {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.serverPushUserOptOut]
            defer { Defaults[.serverPushUserOptOut] = saved }
            Defaults[.serverPushUserOptOut] = false
            try await body()
        }
    }

    @Test("the launch announce carries the device secret")
    func theAnnounceCarriesTheSecret() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        Self.answer(Self.announceURL(baseURL))

        await Self.requests(PushIdentity(uuid: "test-device", secret: Self.secret), baseURL: baseURL)
            .announce(deviceToken: "abcdef")

        let sent = try #require(try Self.sentBodies(to: Self.announceURL(baseURL)).first)
        #expect(sent["device_id"] as? String == "test-device")
        #expect(sent["device_secret"] as? String == Self.secret)
    }

    @Test("a signed-out push opt-out carries the device secret")
    func aSignedOutOptOutCarriesTheSecret() async throws {
        try await Self.withServerPushOptOut {
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            Self.answer(Self.announceURL(baseURL))

            try await Self.requests(PushIdentity(uuid: "test-device", secret: Self.secret), baseURL: baseURL)
                .sendServerPushOptOut(true, deviceToken: "abcdef", for: testSignIn)

            let sent = try #require(try Self.sentBodies(to: Self.announceURL(baseURL)).first)
            #expect(sent["server_push_enabled"] as? Bool == false)
            #expect(sent["device_secret"] as? String == Self.secret)
        }
    }

    @Test("a signed-in registration carries the device secret beside client_device_id")
    func aRegistrationCarriesTheSecret() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        Self.answer(Self.registerURL(baseURL), body: #"{"device_id":"server-device","push_token_id":1}"#)
        let requests = Self.requests(PushIdentity(uuid: "test-device", secret: Self.secret), baseURL: baseURL, signedIn: true)

        try await requests.register(requests.pushTokens(device: "abcdef", pts: nil))

        let sent = try #require(try Self.sentBodies(to: Self.registerURL(baseURL)).first)
        #expect(sent["client_device_id"] as? String == "test-device")
        #expect(sent["device_secret"] as? String == Self.secret)
    }

    @Test("a secret that could not be saved is left out of the announce")
    func anUnsavedSecretIsLeftOut() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        Self.answer(Self.announceURL(baseURL))
        let keychain = FakeIdentityKeychain(unsavable: [AppConstants.KeychainKeys.pushDeviceSecret])
        let identity = PushIdentity.loadOrCreate(from: keychain.store)

        await Self.requests(identity, baseURL: baseURL).announce(deviceToken: "abcdef")

        let sent = try #require(try Self.sentBodies(to: Self.announceURL(baseURL)).first)
        #expect(sent["device_id"] as? String == identity.uuid)
        #expect(sent["device_secret"] == nil)
    }

    @Test("a Keychain that could not be read at launch sends no announce")
    func anUnreadableKeychainSendsNoAnnounce() async {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let keychain = FakeIdentityKeychain(unreadable: [AppConstants.KeychainKeys.pushDeviceId])
        let identity = PushIdentity.loadOrCreate(from: keychain.store)

        await Self.requests(identity, baseURL: baseURL).announce(deviceToken: "abcdef")

        #expect(SettingsAPIStub.requests(under: baseURL).isEmpty)
    }
}
