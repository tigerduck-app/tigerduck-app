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

    private static let refusal = #"{"error":"device_secret_invalid","message":"The device secret is missing or does not match."}"#
    private static let preferences = """
        {"device_id":"server-device","server_push_enabled":false,"sync_courses":true,"sync_course_colors":true,\
        "sync_course_names":true,"sync_assignments":true,"sync_assignment_reminders":true,"sync_live_activity":true,\
        "cloud_sync_enabled":true,"bulletin_push_enabled":true}
        """

    private static func preferencesURL(_ baseURL: URL) -> URL {
        baseURL.appendingPathComponent("devices/test-device/preferences")
    }

    private static func withDeviceDefaults(_ body: () async throws -> Void) async rethrows {
        try await withExclusiveRealDefaults {
            let savedOptOut = Defaults[.serverPushUserOptOut], savedRefusal = Defaults[.pushDeviceSecretRefused]
            defer {
                Defaults[.serverPushUserOptOut] = savedOptOut
                Defaults[.pushDeviceSecretRefused] = savedRefusal
            }
            Defaults[.serverPushUserOptOut] = false
            Defaults[.pushDeviceSecretRefused] = false
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
        try await Self.withDeviceDefaults {
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

    @Test("a refused announce is recorded for the next launch")
    func aRefusedAnnounceIsRecorded() async throws {
        await Self.withDeviceDefaults {
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            Self.answer(Self.announceURL(baseURL), status: 403, body: Self.refusal)

            await Self.requests(PushIdentity(uuid: "test-device", secret: Self.secret), baseURL: baseURL)
                .announce(deviceToken: "abcdef")

            #expect(Defaults[.pushDeviceSecretRefused])
        }
    }

    @Test("an announce turned away for another reason records no refusal")
    func anotherFailureIsNotRecorded() async throws {
        await Self.withDeviceDefaults {
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            Self.answer(
                Self.announceURL(baseURL), status: 429,
                body: #"{"error":"too_many_registration_attempts","message":"Too many registrations; try again later."}"#
            )

            await Self.requests(PushIdentity(uuid: "test-device", secret: Self.secret), baseURL: baseURL)
                .announce(deviceToken: "abcdef")

            #expect(!Defaults[.pushDeviceSecretRefused])
        }
    }

    @Test("a refused signed-out opt-out is kept locally, and the next announce under a new id carries it")
    func aRefusedSignedOutOptOutIsKept() async throws {
        try await Self.withDeviceDefaults {
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            Self.answer(Self.announceURL(baseURL), status: 403, body: Self.refusal)
            Self.answer(Self.announceURL(baseURL))

            try await Self.requests(PushIdentity(uuid: "test-device", secret: Self.secret), baseURL: baseURL)
                .sendServerPushOptOut(true, deviceToken: "abcdef", for: testSignIn)
            #expect(Defaults[.pushDeviceSecretRefused])
            #expect(Defaults[.serverPushUserOptOut])
            await Self.requests(PushIdentity(uuid: "new-device", secret: Self.secret), baseURL: baseURL)
                .announce(deviceToken: "abcdef")

            let next = try #require(try Self.sentBodies(to: Self.announceURL(baseURL)).last)
            #expect(next["device_id"] as? String == "new-device")
            #expect(next["server_push_enabled"] as? Bool == false)
        }
    }

    @Test("a refused signed-in opt-out is recorded and still reaches the preferences PATCH")
    func aRefusedSignedInOptOutStillPatches() async throws {
        try await Self.withDeviceDefaults {
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            Self.answer(Self.announceURL(baseURL), status: 403, body: Self.refusal)
            Self.answer(Self.preferencesURL(baseURL), body: Self.preferences)

            try await Self.requests(PushIdentity(uuid: "test-device", secret: Self.secret), baseURL: baseURL, signedIn: true)
                .sendServerPushOptOut(true, deviceToken: "abcdef", for: testSignIn)

            let patch = try #require(try Self.sentBodies(to: Self.preferencesURL(baseURL)).first)
            #expect(patch["server_push_enabled"] as? Bool == false)
            #expect(Defaults[.pushDeviceSecretRefused])
            #expect(Defaults[.serverPushUserOptOut])
        }
    }

    @Test("an announce with the secret and a push token that goes through clears the refusal")
    func aClaimThatGoesThroughClearsTheRefusal() async {
        await Self.withDeviceDefaults {
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            Defaults[.pushDeviceSecretRefused] = true
            Self.answer(Self.announceURL(baseURL))

            await Self.requests(PushIdentity(uuid: "test-device", secret: Self.secret), baseURL: baseURL)
                .announce(deviceToken: "abcdef")

            #expect(!Defaults[.pushDeviceSecretRefused])
        }
    }

    @Test(
        "an announce that goes through without the secret or a push token keeps the refusal",
        arguments: [(secret, nil), (nil, "abcdef")] as [(String?, String?)]
    )
    func anAnnounceThatBindsNothingKeepsTheRefusal(secret: String?, deviceToken: String?) async {
        await Self.withDeviceDefaults {
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            Defaults[.pushDeviceSecretRefused] = true
            Self.answer(Self.announceURL(baseURL))

            await Self.requests(PushIdentity(uuid: "test-device", secret: secret), baseURL: baseURL)
                .announce(deviceToken: deviceToken)

            #expect(Defaults[.pushDeviceSecretRefused])
        }
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
