import Defaults
import Foundation
import Testing
import os
@testable import TigerDuck

@Suite("Push device registration")
@MainActor
struct PushRegistrationServiceTests {

    private static func makeService(
        baseURL: URL,
        debounces: OSAllocatedUnfairLock<[Duration]> = .init(initialState: []),
        retries: OSAllocatedUnfairLock<[Duration]> = .init(initialState: []),
        authHeader: @escaping @Sendable () async -> String? = { "Bearer test" }
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
            debounceSleep: { window in debounces.withLock { $0.append(window) } },
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

    private static func expectAttempt(_ baseURL: URL, registrations: Int) {
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data("{}".utf8)), for: announceURL(baseURL))
        for _ in 0..<registrations {
            SettingsAPIStub.enqueue(
                .init(statusCode: 200, body: Data(#"{"device_id":"server-device","push_token_id":1}"#.utf8)),
                for: registerURL(baseURL)
            )
        }
    }

    private static func expectRefusedAttempt(_ baseURL: URL) {
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data("{}".utf8)), for: announceURL(baseURL))
        SettingsAPIStub.enqueue(
            .init(statusCode: 401, body: Data(#"{"detail":"session_revoked"}"#.utf8)),
            for: registerURL(baseURL)
        )
    }

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

    private static func sentRegistrations(_ baseURL: URL) throws -> [[String: Any]] {
        try SettingsAPIStub.requests(for: registerURL(baseURL)).map { request in
            let body = try #require(SettingsAPIStub.bodyData(from: request))
            return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
    }

    private static func tokenKind(_ registration: [String: Any]) -> String? {
        (registration["push_token"] as? [String: Any])?["token_kind"] as? String
    }

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
            Defaults[.bulletinPushEnabled] = false
            Defaults[.serverPushUserOptOut] = true
            try await body()
        }
    }

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

    @Test("a sync-preferences PATCH that fails is sent again once a registration goes through")
    func failedSyncPreferencesPatchIsResentAfterRegistration() async throws {
        try await Self.withSyncPreferences {
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let service = Self.makeService(baseURL: baseURL)

            Defaults[.syncAssignmentReminders] = false
            await service.updateSyncPreferences()
            #expect(Defaults[.syncPreferencesPushPending])

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

            await service.update(deviceToken: Data([0xAB, 0xCD, 0xEF]))
            await service.awaitPendingRegistration()
            #expect(debounces.withLock { $0 } == [.milliseconds(250)])

            let sent = try Self.sentRegistrations(baseURL)
            try #require(sent.count == 1)
            let registration = sent[0]
            let token = try #require(registration["push_token"] as? [String: Any])
            #expect(token["token_kind"] as? String == "standard")
            #expect(token["token_value"] as? String == "abcdef")

            #expect(registration["client_device_id"] as? String == "test-device")
            #expect(registration["platform"] as? String == "ios")
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            #expect(appVersion != nil)
            #expect(registration["app_version"] as? String == appVersion)
            #expect(registration["locale"] as? String == PushRegistrationService.currentLocaleTag)
            #expect(registration["cloud_sync_enabled"] as? Bool == Defaults[.cloudSyncEnabled])

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

    @Test("a registration that gave up goes again after a sign-in, and its error clears")
    func registrationThatGaveUpRegistersAgainAfterSignIn() async throws {
        try await Self.withSyncPreferences {
            Defaults[.syncPreferencesPushPending] = false
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let retries = OSAllocatedUnfairLock<[Duration]>(initialState: [])
            let service = Self.makeService(baseURL: baseURL, retries: retries)
            try await Self.registerUntilGivenUp(service, baseURL: baseURL, retries: retries)

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

    @Test("a return to the app after a registration gave up registers the device again")
    func returnToAppRegistersAgainAfterARegistrationGaveUp() async throws {
        try await Self.withSyncPreferences {
            Defaults[.syncPreferencesPushPending] = false
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let retries = OSAllocatedUnfairLock<[Duration]>(initialState: [])
            let service = Self.makeService(baseURL: baseURL, retries: retries)
            try await Self.registerUntilGivenUp(service, baseURL: baseURL, retries: retries)

            Self.expectAttempt(baseURL, registrations: 1)
            await service.registerAgainIfGaveUp()
            await service.awaitPendingRegistration()

            let registrations = try Self.sentRegistrations(baseURL)
            #expect(registrations.count == 5)
            let snapshot = await service.snapshot()
            #expect(snapshot.lastError == nil)
            #expect(snapshot.lastRegisteredAt != nil)
        }
    }

    @Test("a return to the app after a registration went through sends no second one")
    func returnToAppAfterARegistrationSendsNoSecond() async throws {
        try await Self.withSyncPreferences {
            Defaults[.syncPreferencesPushPending] = false
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let service = Self.makeService(baseURL: baseURL)
            Self.expectAttempt(baseURL, registrations: 1)
            await service.update(deviceToken: Data([0xAB, 0xCD, 0xEF]))
            await service.awaitPendingRegistration()

            await service.registerAgainIfGaveUp()
            await service.awaitPendingRegistration()

            let registrations = try Self.sentRegistrations(baseURL)
            #expect(registrations.count == 1)
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

    private static func serverCloudSyncEnabled(_ baseURL: URL) throws -> Bool? {
        try SettingsAPIStub.requests(under: baseURL).compactMap { request -> Bool? in
            guard let body = SettingsAPIStub.bodyData(from: request) else { return nil }
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            return json?["cloud_sync_enabled"] as? Bool
        }.last
    }

    @Test("turning TigerSync off while a registration is out leaves the server off")
    func switchTurnedOffDuringARegistrationEndsOff() async throws {
        try await Self.withSyncPreferences {
            let savedSync = Defaults[.cloudSyncEnabled]
            defer { Defaults[.cloudSyncEnabled] = savedSync }
            Defaults[.syncPreferencesPushPending] = false
            Defaults[.cloudSyncEnabled] = true
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let service = Self.makeService(baseURL: baseURL)
            Self.expectAttempt(baseURL, registrations: 1)
            await service.update(deviceToken: Data([0xAB, 0xCD, 0xEF]))
            await service.awaitPendingRegistration()

            let gate = SettingsAPIStub.ReplyGate()
            defer { gate.open() }
            let registered = Data(#"{"device_id":"server-device","push_token_id":1}"#.utf8)
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data("{}".utf8)), for: Self.announceURL(baseURL))
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: registered, gate: gate), for: Self.registerURL(baseURL))
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: registered), for: Self.registerURL(baseURL))
            SettingsAPIStub.enqueue(
                .init(statusCode: 200, body: Self.preferencesBody(bulletinPushEnabled: true)),
                for: Self.preferencesURL(baseURL)
            )
            await service.update(ptsTokenHex: "a1b2")
            try await waitUntil { SettingsAPIStub.requests(for: Self.registerURL(baseURL)).count == 2 }

            Defaults[.cloudSyncEnabled] = false
            let patch = Task { await service.updateCloudSyncEnabled(false) }
            for _ in 0..<60 where SettingsAPIStub.requests(for: Self.preferencesURL(baseURL)).isEmpty {
                try await Task.sleep(for: .milliseconds(5))
            }
            gate.open()
            await patch.value
            await service.awaitPendingRegistration()

            #expect(try Self.serverCloudSyncEnabled(baseURL) == false)
            #expect(SettingsAPIStub.requests(for: Self.preferencesURL(baseURL)).count == 1)
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

    @Test("a registration that finds no session is followed at once by one with the session restored meanwhile")
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
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data("{}".utf8)), for: Self.announceURL(baseURL))
            Self.expectAttempt(baseURL, registrations: 1)

            await service.update(deviceToken: Data([0xAB, 0xCD, 0xEF]))
            await session.waitUntilHeld()
            session.signIn()
            await service.registerAgain()
            session.release()
            await service.awaitPendingRegistration()

            #expect(retries.withLock { $0 }.isEmpty)
            #expect(debounces.withLock { $0 } == [.milliseconds(250), .milliseconds(250)])
            #expect(SettingsAPIStub.requests(for: Self.announceURL(baseURL)).count == 2)
            let registrations = SettingsAPIStub.requests(for: Self.registerURL(baseURL))
            try #require(registrations.count == 1)
            #expect(registrations[0].value(forHTTPHeaderField: "Authorization") == HeldRegistrationSession.bearer)
            let snapshot = await service.snapshot()
            #expect(snapshot.lastError == nil)
            #expect(snapshot.lastRegisteredAt != nil)
        }
    }

    @Test("a registration that finds no session says so, until one goes out and the backend refuses it")
    func registrationRecordsWhetherItFoundNoSession() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let header = OSAllocatedUnfairLock<String?>(initialState: nil)
        let service = Self.makeService(baseURL: baseURL, authHeader: { header.withLock { $0 } })
        for _ in 0..<4 {
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data("{}".utf8)), for: Self.announceURL(baseURL))
        }

        await service.update(deviceToken: Data([0xAB, 0xCD, 0xEF]))
        await service.awaitPendingRegistration()
        #expect(await service.snapshot().lastAttemptFoundNoSession)

        header.withLock { $0 = "Bearer test" }
        for _ in 0..<4 { Self.expectRefusedAttempt(baseURL) }
        await service.registerAgain()
        await service.awaitPendingRegistration()

        try #require(SettingsAPIStub.requests(for: Self.registerURL(baseURL)).count == 4)
        #expect(await !service.snapshot().lastAttemptFoundNoSession)
    }

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
        if calls.withLock({ count in count += 1; return count }) == 1 {
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
