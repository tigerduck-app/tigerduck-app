// `PushRegistrationService` registers on any APNs token and never waits for a push-to-start
// (PTS) token, which exists only while Live Activities are on. Assignment reminders arrive only
// by push to the standard token, and the register carries app version, locale and cloud-sync flag.
import Defaults
import Foundation
import Testing
import os
@testable import TigerDuck

@Suite("Push device registration")
@MainActor
struct PushRegistrationServiceTests {

    // MARK: - Fixtures

    private static func makeService(
        baseURL: URL,
        debounces: OSAllocatedUnfairLock<[Duration]> = .init(initialState: []),
        retries: OSAllocatedUnfairLock<[Duration]> = .init(initialState: []),
        authHeader: @escaping @Sendable () async -> String? = { nil }
    ) -> PushRegistrationService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return PushRegistrationService(
            identity: PushIdentity(uuid: "test-device"),
            apiClient: PushAPIClient(
                baseURLProvider: { baseURL },
                session: URLSession(configuration: config),
                authHeaderProvider: authHeader
            ),
            deviceClass: "iphone",
            // Each test awaits its attempt with `awaitPendingRegistration()`, so the debounce
            // has nothing to merge: it ends at once and only records the window it asked for.
            debounceSleep: { window in debounces.withLock { $0.append(window) } },
            // The backoff after a failed attempt likewise ends at once.
            retrySleep: { delay in retries.withLock { $0.append(delay) } }
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

    /// Stubs one attempt whose registration the backend refuses the way it refuses a request
    /// that carries no access token.
    private static func expectRefusedAttempt(_ baseURL: URL) {
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data("{}".utf8)), for: announceURL(baseURL))
        SettingsAPIStub.enqueue(
            .init(statusCode: 401, body: Data(#"{"detail":"missing_bearer_token"}"#.utf8)),
            for: registerURL(baseURL)
        )
    }

    /// Registers the standard token while the backend refuses every attempt, until the backoff
    /// gives up: the first attempt and three retries.
    private static func registerUntilGivenUp(
        _ service: PushRegistrationService,
        baseURL: URL,
        retries: OSAllocatedUnfairLock<[Duration]>
    ) async throws {
        for _ in 0..<4 { expectRefusedAttempt(baseURL) }
        await service.update(deviceToken: Data([0xAB, 0xCD, 0xEF]))
        await service.awaitPendingRegistration()
        try #require(retries.withLock { $0 } == [.seconds(30), .seconds(90), .seconds(270)])
        let snapshot = await service.snapshot()
        try #require(snapshot.lastError != nil)
        try #require(snapshot.lastRegisteredAt == nil)
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
            let debounces = OSAllocatedUnfairLock<[Duration]>(initialState: [])
            let service = Self.makeService(baseURL: baseURL, debounces: debounces)
            Self.expectAttempt(baseURL, registrations: 1)

            // Live Activities are off, so iOS never hands over a PTS token.
            await service.update(deviceToken: Data([0xAB, 0xCD, 0xEF]))
            await service.awaitPendingRegistration()
            #expect(debounces.withLock { $0 } == [.milliseconds(250)])

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
        let debounces = OSAllocatedUnfairLock<[Duration]>(initialState: [])
        let service = Self.makeService(baseURL: baseURL, debounces: debounces)

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
        #expect(debounces.withLock { $0 } == [.milliseconds(250), .milliseconds(250)])

        let secondAttempt = Array(try Self.sentRegistrations(baseURL).dropFirst())
        let pts = try #require(secondAttempt.first { Self.tokenKind($0) == "push_to_start" })
        let ptsToken = try #require(pts["push_token"] as? [String: Any])
        #expect(ptsToken["token_value"] as? String == "a1b2")
        #expect(ptsToken["scope_key"] as? String == "TigerDuckActivityAttributes")
        #expect(secondAttempt.contains { Self.tokenKind($0) == "standard" })
    }

    // MARK: - Registering again after a failed registration
    // https://github.com/tigerduck-app/tigerduck-app/issues/378

    @Test("a registration that gave up goes again after a sign-in, and its error clears")
    func registrationThatGaveUpRegistersAgainAfterSignIn() async throws {
        try await Self.withSyncPreferences {
            Defaults[.syncPreferencesPushPending] = false
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let retries = OSAllocatedUnfairLock<[Duration]>(initialState: [])
            let service = Self.makeService(baseURL: baseURL, retries: retries)
            try await Self.registerUntilGivenUp(service, baseURL: baseURL, retries: retries)

            // What a sign-in, a relogin and `ensureBackendSignedIn` end in, through
            // `PushCoordinator.refreshRegistrationAfterAuth()`.
            Self.expectAttempt(baseURL, registrations: 1)
            await service.registerAgain()
            await service.awaitPendingRegistration()

            let registrations = try Self.sentRegistrations(baseURL)
            #expect(registrations.count == 5)
            let snapshot = await service.snapshot()
            #expect(snapshot.lastError == nil)
            #expect(snapshot.lastRegisteredAt != nil)
        }
    }

    @Test("turning TigerSync on after a registration gave up registers the device again")
    func turningSyncOnRegistersAgainAfterAFailedRegistration() async throws {
        try await Self.withSyncPreferences {
            Defaults[.syncPreferencesPushPending] = false
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let retries = OSAllocatedUnfairLock<[Duration]>(initialState: [])
            let service = Self.makeService(baseURL: baseURL, retries: retries)
            try await Self.registerUntilGivenUp(service, baseURL: baseURL, retries: retries)

            SettingsAPIStub.enqueue(
                .init(statusCode: 200, body: Self.preferencesBody(bulletinPushEnabled: true)),
                for: Self.preferencesURL(baseURL)
            )
            Self.expectAttempt(baseURL, registrations: 1)
            await service.updateCloudSyncEnabled(true)
            await service.awaitPendingRegistration()

            let registrations = try Self.sentRegistrations(baseURL)
            #expect(registrations.count == 5)
            let snapshot = await service.snapshot()
            #expect(snapshot.lastError == nil)
            #expect(snapshot.lastRegisteredAt != nil)
        }
    }

    @Test("turning TigerSync on after a registration went through sends no second one")
    func turningSyncOnAfterARegistrationSendsNoSecond() async throws {
        try await Self.withSyncPreferences {
            Defaults[.syncPreferencesPushPending] = false
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let service = Self.makeService(baseURL: baseURL)
            Self.expectAttempt(baseURL, registrations: 1)
            await service.update(deviceToken: Data([0xAB, 0xCD, 0xEF]))
            await service.awaitPendingRegistration()

            SettingsAPIStub.enqueue(
                .init(statusCode: 200, body: Self.preferencesBody(bulletinPushEnabled: true)),
                for: Self.preferencesURL(baseURL)
            )
            await service.updateCloudSyncEnabled(true)
            await service.awaitPendingRegistration()

            let registrations = try Self.sentRegistrations(baseURL)
            #expect(registrations.count == 1)
        }
    }

    @Test("a registration already running when the session comes back is not started a second time")
    func runningRegistrationIsNotStartedAgain() async throws {
        try await Self.withSyncPreferences {
            Defaults[.syncPreferencesPushPending] = false
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let session = HeldRegistrationSession(signedIn: true)
            let service = Self.makeService(baseURL: baseURL, authHeader: { await session.header() })
            Self.expectAttempt(baseURL, registrations: 1)

            await service.update(deviceToken: Data([0xAB, 0xCD, 0xEF]))
            await session.waitUntilHeld()
            await service.registerAgain()
            session.release()
            await service.awaitPendingRegistration()

            #expect(SettingsAPIStub.requests(for: Self.announceURL(baseURL)).count == 1)
            let registrations = try Self.sentRegistrations(baseURL)
            #expect(registrations.count == 1)
            #expect(await service.snapshot().lastError == nil)
        }
    }

    @Test("a registration that went out with no session is followed at once by one with the session restored meanwhile")
    func registrationWithoutSessionIsFollowedAtOnce() async throws {
        try await Self.withSyncPreferences {
            Defaults[.syncPreferencesPushPending] = false
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let session = HeldRegistrationSession(signedIn: false)
            let debounces = OSAllocatedUnfairLock<[Duration]>(initialState: [])
            let retries = OSAllocatedUnfairLock<[Duration]>(initialState: [])
            let service = Self.makeService(
                baseURL: baseURL, debounces: debounces, retries: retries,
                authHeader: { await session.header() }
            )
            Self.expectRefusedAttempt(baseURL)
            Self.expectAttempt(baseURL, registrations: 1)

            await service.update(deviceToken: Data([0xAB, 0xCD, 0xEF]))
            await session.waitUntilHeld()
            // A sign-in lands while that registration is on its way without a bearer.
            session.signIn()
            await service.registerAgain()
            session.release()
            await service.awaitPendingRegistration()

            #expect(retries.withLock { $0 }.isEmpty)
            #expect(debounces.withLock { $0 } == [.milliseconds(250), .milliseconds(250)])
            let registrations = SettingsAPIStub.requests(for: Self.registerURL(baseURL))
            try #require(registrations.count == 2)
            #expect(registrations[0].value(forHTTPHeaderField: "Authorization") == nil)
            #expect(registrations[1].value(forHTTPHeaderField: "Authorization") == HeldRegistrationSession.bearer)
            let snapshot = await service.snapshot()
            #expect(snapshot.lastError == nil)
            #expect(snapshot.lastRegisteredAt != nil)
        }
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

/// The bearer for each request while signed in, nil before `signIn()`. Holds an attempt's
/// registration POST, its second request after the announce, until `release()`, so a test can
/// act while that registration is running; the held request keeps the answer it was asked for.
private final class HeldRegistrationSession: Sendable {
    static let bearer = "Bearer restored"

    private let held: AsyncStream<Void>
    private let heldContinuation: AsyncStream<Void>.Continuation
    private let released: AsyncStream<Void>
    private let releasedContinuation: AsyncStream<Void>.Continuation
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    private let isSignedIn: OSAllocatedUnfairLock<Bool>

    init(signedIn: Bool) {
        (held, heldContinuation) = AsyncStream.makeStream()
        (released, releasedContinuation) = AsyncStream.makeStream()
        isSignedIn = OSAllocatedUnfairLock(initialState: signedIn)
    }

    func header() async -> String? {
        let header = isSignedIn.withLock { $0 } ? Self.bearer : nil
        if calls.withLock({ count in count += 1; return count }) == 2 {
            heldContinuation.yield()
            for await _ in released {}
        }
        return header
    }

    func signIn() {
        isSignedIn.withLock { $0 = true }
    }

    func waitUntilHeld() async {
        for await _ in held { return }
    }

    func release() {
        releasedContinuation.finish()
    }
}
