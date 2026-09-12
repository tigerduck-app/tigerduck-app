// `PushRegistrationService` registers the device as soon as it holds any
// APNs token, and attaches the push-to-start (PTS) token when that arrives.
//
// The standard APNs token is where the backend sends assignment reminders,
// and the registration is how the server learns this device's app version,
// locale and cloud-sync flag. A PTS token only exists while Live Activities
// are enabled. Registration used to wait for one, so a device with Live
// Activities switched off never registered at all — and, with reminders no
// longer scheduled locally, received none.
//
// Driven through the real `PushAPIClient` over `SettingsAPIStub`, so the
// assertions read the request bodies that actually went out.
import Defaults
import Foundation
import Testing
@testable import TigerDuck

@Suite("Push device registration")
@MainActor
struct PushRegistrationServiceTests {

    // MARK: - Fixtures

    private static func makeService(baseURL: URL) -> PushRegistrationService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return PushRegistrationService(
            identity: PushIdentity(uuid: "test-device"),
            apiClient: PushAPIClient(
                baseURLProvider: { baseURL },
                session: URLSession(configuration: config)
            ),
            deviceClass: "iphone"
        )
    }

    private static func registerURL(_ baseURL: URL) -> URL {
        baseURL.appendingPathComponent("devices/register")
    }

    private static func announceURL(_ baseURL: URL) -> URL {
        baseURL.appendingPathComponent("devices/anonymous")
    }

    /// Stubs one registration attempt: the anonymous announce, then
    /// `registrations` successful POSTs to `/devices/register`.
    private static func expectAttempt(_ baseURL: URL, registrations: Int) {
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data("{}".utf8)), for: announceURL(baseURL))
        for _ in 0..<registrations {
            SettingsAPIStub.enqueue(
                .init(statusCode: 200, body: Data(#"{"device_id":"server-device","push_token_id":1}"#.utf8)),
                for: registerURL(baseURL)
            )
        }
    }

    /// Every `/devices/register` body sent so far, in order.
    private static func sentRegistrations(_ baseURL: URL) throws -> [[String: Any]] {
        try SettingsAPIStub.requests(for: registerURL(baseURL)).map { request in
            let body = try #require(SettingsAPIStub.bodyData(from: request))
            return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
    }

    private static func tokenKind(_ registration: [String: Any]) -> String? {
        (registration["push_token"] as? [String: Any])?["token_kind"] as? String
    }

    // MARK: - Tests

    @Test("with only the standard APNs token the device registers — it does not wait for a push-to-start token")
    func registersWithoutPushToStartToken() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let service = Self.makeService(baseURL: baseURL)
        Self.expectAttempt(baseURL, registrations: 1)

        // Live Activities are off, so iOS never hands over a PTS token.
        await service.update(deviceToken: Data([0xAB, 0xCD, 0xEF]))
        await service.awaitPendingRegistration()

        let sent = try Self.sentRegistrations(baseURL)
        try #require(sent.count == 1)
        let registration = sent[0]
        let token = try #require(registration["push_token"] as? [String: Any])
        #expect(token["token_kind"] as? String == "standard")
        #expect(token["token_value"] as? String == "abcdef")

        // What the backend's reminder gate reads off the device row.
        #expect(registration["client_device_id"] as? String == "test-device")
        #expect(registration["platform"] as? String == "ios")
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        #expect(appVersion != nil)
        #expect(registration["app_version"] as? String == appVersion)
        #expect(registration["locale"] as? String == PushRegistrationService.currentLocaleTag)
        #expect(registration["cloud_sync_enabled"] as? Bool == Defaults[.cloudSyncEnabled])

        #expect(await service.snapshot().lastRegisteredAt != nil)
    }

    @Test("a push-to-start token that arrives later is attached by a second registration")
    func laterPushToStartTokenIsAttached() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let service = Self.makeService(baseURL: baseURL)

        Self.expectAttempt(baseURL, registrations: 1)
        await service.update(deviceToken: Data([0x01, 0x02]))
        await service.awaitPendingRegistration()
        try #require(try Self.sentRegistrations(baseURL).map(Self.tokenKind) == ["standard"])

        // The user turns Live Activities on and iOS hands over a PTS token.
        // `/devices/register` carries exactly one `push_token` per request,
        // so attaching it takes a registration of its own; the attempt
        // re-sends the standard token too, which the server upserts.
        Self.expectAttempt(baseURL, registrations: 2)
        await service.update(ptsTokenHex: "a1b2")
        await service.awaitPendingRegistration()

        let secondAttempt = Array(try Self.sentRegistrations(baseURL).dropFirst())
        let pts = try #require(secondAttempt.first { Self.tokenKind($0) == "push_to_start" })
        let ptsToken = try #require(pts["push_token"] as? [String: Any])
        #expect(ptsToken["token_value"] as? String == "a1b2")
        #expect(ptsToken["scope_key"] as? String == "TigerDuckActivityAttributes")
        #expect(secondAttempt.contains { Self.tokenKind($0) == "standard" })
    }
}
