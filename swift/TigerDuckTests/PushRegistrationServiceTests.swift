// `PushRegistrationService` registers on any APNs token and never waits for a push-to-start
// (PTS) token, which exists only while Live Activities are on. Assignment reminders arrive only
// by push to the standard token, and the register carries app version, locale and cloud-sync flag.
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
            deviceClass: "iphone",
            // Each test awaits its attempt with `awaitPendingRegistration()`, so the debounce
            // has nothing to merge and ends at once.
            debounceSleep: { _ in }
        )
    }

    private static func registerURL(_ baseURL: URL) -> URL {
        baseURL.appendingPathComponent("devices/register")
    }

    private static func announceURL(_ baseURL: URL) -> URL {
        baseURL.appendingPathComponent("devices/anonymous")
    }

    private static func preferencesURL(_ baseURL: URL) -> URL {
        baseURL.appendingPathComponent("devices/test-device/preferences")
    }

    /// The 200 body `PATCH /devices/{id}/preferences` answers with, echoing
    /// the bulletin flag the way the backend does (the column is NOT NULL
    /// with a `server_default`). `nil` omits the key entirely, which is
    /// what a backend without the column answers.
    private static func preferencesBody(bulletinPushEnabled: Bool?) -> Data {
        let echo = bulletinPushEnabled.map { ",\n  \"bulletin_push_enabled\": \($0)" } ?? ""
        return Data("""
        {
          "device_id": "server-device",
          "server_push_enabled": true,
          "sync_courses": true,
          "sync_course_colors": true,
          "sync_course_names": true,
          "sync_assignments": true,
          "cloud_sync_enabled": true\(echo)
        }
        """.utf8)
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

    /// Runs `body` with the two delivery-preference flags the register body
    /// carries pinned to their non-default values, then puts both back.
    ///
    /// Pinned rather than re-read at assertion time: the register sends the inverse of
    /// `serverPushUserOptOut`, and an expectation derived the same way would pass without the `!`.
    /// Both keys live in process-wide `UserDefaults` (see `AppDefaults.swift`), so this takes the
    /// shared gate: this suite's tests run concurrently with each other and with
    /// `BulletinPushOptOutMigrationTests`, which arranges the same keys.
    private static func withPinnedDeliveryPreferences(
        _ body: () async throws -> Void
    ) async rethrows {
        try await withExclusiveRealDefaults {
            let savedBulletin = Defaults[.bulletinPushEnabled]
            let savedOptOut = Defaults[.serverPushUserOptOut]
            defer {
                Defaults[.bulletinPushEnabled] = savedBulletin
                Defaults[.serverPushUserOptOut] = savedOptOut
            }
            // Shipped defaults are the opposite of both: bulletins on, and
            // not opted out of operator pushes.
            Defaults[.bulletinPushEnabled] = false
            Defaults[.serverPushUserOptOut] = true
            try await body()
        }
    }

    /// Runs `body` with `bulletinPushEnabled` set to `start` and restores
    /// whatever was there before — `updateBulletinPushEnabled` writes that
    /// key into process-wide UserDefaults on success. Same gate, same
    /// reason.
    private static func withBulletinPreference(
        startingAt start: Bool,
        _ body: () async throws -> Void
    ) async rethrows {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.bulletinPushEnabled]
            defer { Defaults[.bulletinPushEnabled] = saved }
            Defaults[.bulletinPushEnabled] = start
            try await body()
        }
    }

    /// Runs `body` with the six sync switches and
    /// `syncPreferencesPushPending` put back as found afterwards —
    /// `updateSyncPreferences` reads the one and writes the other in
    /// process-wide UserDefaults. Same gate, same reason.
    private static func withSyncPreferences(
        _ body: () async throws -> Void
    ) async rethrows {
        try await withExclusiveRealDefaults {
            let saved = (
                Defaults[.syncCourses],
                Defaults[.syncCourseColors],
                Defaults[.syncCourseNames],
                Defaults[.syncAssignments],
                Defaults[.syncAssignmentReminders],
                Defaults[.syncLiveActivity],
                Defaults[.syncPreferencesPushPending]
            )
            defer {
                Defaults[.syncCourses] = saved.0
                Defaults[.syncCourseColors] = saved.1
                Defaults[.syncCourseNames] = saved.2
                Defaults[.syncAssignments] = saved.3
                Defaults[.syncAssignmentReminders] = saved.4
                Defaults[.syncLiveActivity] = saved.5
                Defaults[.syncPreferencesPushPending] = saved.6
            }
            try await body()
        }
    }

    // MARK: - Tests

    @Test("a sync-preferences PATCH that fails is sent again once a registration goes through")
    func failedSyncPreferencesPatchIsResentAfterRegistration() async throws {
        try await Self.withSyncPreferences {
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let service = Self.makeService(baseURL: baseURL)

            // Assignment reminders switched off with no connection: the
            // PATCH never lands (nothing is stubbed for it).
            Defaults[.syncAssignmentReminders] = false
            await service.updateSyncPreferences()
            #expect(Defaults[.syncPreferencesPushPending])

            // The next registration reaches the server, and the switches
            // follow it there.
            Self.expectAttempt(baseURL, registrations: 1)
            SettingsAPIStub.enqueue(
                .init(statusCode: 200, body: Self.preferencesBody(bulletinPushEnabled: true)),
                for: Self.preferencesURL(baseURL)
            )
            await service.update(deviceToken: Data([0xAB, 0xCD, 0xEF]))
            await service.awaitPendingRegistration()

            let patches = SettingsAPIStub.requests(for: Self.preferencesURL(baseURL))
            try #require(patches.count == 2)
            let body = try #require(SettingsAPIStub.bodyData(from: patches[1]))
            let resent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(resent["sync_assignment_reminders"] as? Bool == false)
            #expect(!Defaults[.syncPreferencesPushPending])
        }
    }

    @Test("a registration with no sync-preferences PATCH outstanding sends none")
    func registrationWithNothingPendingSendsNoSyncPreferences() async throws {
        try await Self.withSyncPreferences {
            Defaults[.syncPreferencesPushPending] = false
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let service = Self.makeService(baseURL: baseURL)
            Self.expectAttempt(baseURL, registrations: 1)

            await service.update(deviceToken: Data([0xAB, 0xCD, 0xEF]))
            await service.awaitPendingRegistration()

            let registrations = try Self.sentRegistrations(baseURL)
            #expect(registrations.count == 1)
            #expect(SettingsAPIStub.requests(for: Self.preferencesURL(baseURL)).isEmpty)
        }
    }

    @Test("with only the standard APNs token the device registers — it does not wait for a push-to-start token")
    func registersWithoutPushToStartToken() async throws {
        try await Self.withPinnedDeliveryPreferences {
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

            // Every register carries both, so a migrated value or a missed PATCH self-heals. Both
            // are pinned opposite their shipped defaults: ignoring the bulletin flag, or losing the
            // `!` before `serverPushUserOptOut`, would invert the user's choice on every launch.
            #expect(registration["bulletin_push_enabled"] as? Bool == false)
            #expect(registration["server_push_enabled"] as? Bool == false)

            #expect(await service.snapshot().lastRegisteredAt != nil)
        }
    }

    @Test("a push-to-start token that arrives later is attached by a second registration")
    func laterPushToStartTokenIsAttached() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let service = Self.makeService(baseURL: baseURL)

        Self.expectAttempt(baseURL, registrations: 1)
        await service.update(deviceToken: Data([0x01, 0x02]))
        await service.awaitPendingRegistration()
        try #require(try Self.sentRegistrations(baseURL).map(Self.tokenKind) == ["standard"])

        // Live Activities turn on and iOS hands over a PTS token. `/devices/register` takes a
        // single `push_token` per request, so attaching it needs a registration of its own; the
        // attempt re-sends the standard token too, which the server upserts.
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

    // MARK: - The bulletin toggle PATCHes before it persists

    @Test("a bulletin opt-out the server rejects leaves the local preference alone")
    func rejectedBulletinPatchDoesNotPersist() async throws {
        await Self.withBulletinPreference(startingAt: true) {
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let service = Self.makeService(baseURL: baseURL)
            SettingsAPIStub.enqueue(
                .init(statusCode: 500, body: Data(#"{"detail":"internal_error"}"#.utf8)),
                for: Self.preferencesURL(baseURL)
            )

            await #expect(throws: (any Error).self) {
                try await service.updateBulletinPushEnabled(false)
            }

            // The page reads this key through `@Default`. Persisting before the response would
            // show bulletins off while the server keeps sending them, with nothing to correct it
            // until the next register.
            #expect(Defaults[.bulletinPushEnabled] == true)
        }
    }

    @Test("a bulletin opt-out the server accepts is persisted locally")
    func acceptedBulletinPatchPersists() async throws {
        try await Self.withBulletinPreference(startingAt: true) {
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let service = Self.makeService(baseURL: baseURL)
            SettingsAPIStub.enqueue(
                .init(statusCode: 200, body: Self.preferencesBody(bulletinPushEnabled: false)),
                for: Self.preferencesURL(baseURL)
            )

            try await service.updateBulletinPushEnabled(false)

            #expect(Defaults[.bulletinPushEnabled] == false)
        }
    }

    @Test("a 200 that does not come back carrying the new value is not treated as success")
    func unconfirmedBulletinPatchDoesNotPersist() async throws {
        await Self.withBulletinPreference(startingAt: true) {
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let service = Self.makeService(baseURL: baseURL)
            // A backend without the column (rolled back, self-hosted, or older than this build)
            // ignores the key and answers 200 without it. Nothing changed server-side, so treating
            // it as success would leave the page saying bulletins are off while they keep arriving.
            SettingsAPIStub.enqueue(
                .init(statusCode: 200, body: Self.preferencesBody(bulletinPushEnabled: nil)),
                for: Self.preferencesURL(baseURL)
            )

            await #expect(throws: (any Error).self) {
                try await service.updateBulletinPushEnabled(false)
            }

            #expect(Defaults[.bulletinPushEnabled] == true)
        }
    }

    @Test("a 200 echoing the opposite value is not treated as success either")
    func contradictedBulletinPatchDoesNotPersist() async throws {
        await Self.withBulletinPreference(startingAt: true) {
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let service = Self.makeService(baseURL: baseURL)
            SettingsAPIStub.enqueue(
                .init(statusCode: 200, body: Self.preferencesBody(bulletinPushEnabled: true)),
                for: Self.preferencesURL(baseURL)
            )

            await #expect(throws: (any Error).self) {
                try await service.updateBulletinPushEnabled(false)
            }

            #expect(Defaults[.bulletinPushEnabled] == true)
        }
    }
}
