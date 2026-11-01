import Foundation
import os
import Testing
@testable import TigerDuck

@MainActor
struct MoodleNotificationSettingsTests {
    private typealias Fixtures = MoodleNotificationFixtures

    /// A site that keeps the preferences a write stores, optionally holding each write at a gate.
    private final class Site: @unchecked Sendable {
        private let lock = NSLock()
        private var held: MoodleNotificationMatrix
        private var sent: [MoodleNotificationMatrix.Preference] = []
        private var reads = 0
        private let gate: ManualSleeper?
        private let failure: (any Error)?
        /// What the server shows after a write, when it holds something else than was sent.
        private let afterWrite: MoodleNotificationMatrix?

        init(
            _ matrix: MoodleNotificationMatrix, gate: ManualSleeper? = nil, failure: (any Error)? = nil,
            afterWrite: MoodleNotificationMatrix? = nil
        ) {
            held = matrix
            self.gate = gate
            self.failure = failure
            self.afterWrite = afterWrite
        }

        var saves: [MoodleNotificationMatrix.Preference] { lock.withLock { sent } }
        var loads: Int { lock.withLock { reads } }

        var api: MoodleNotificationAPI {
            MoodleNotificationAPI(
                load: {
                    self.lock.withLock {
                        self.reads += 1
                        return self.held
                    }
                },
                save: { preference, _ in
                    self.lock.withLock { self.sent.append(preference) }
                    await self.gate?.sleep(for: .seconds(1))
                    if let failure = self.failure { throw failure }
                    self.lock.withLock { self.held = self.afterWrite ?? self.held.replacing(preference) }
                }
            )
        }
    }

    private static let forum = Fixtures.preference("mod_forum_posts", enabled: ["popup"])
    private static let digest = Fixtures.preference("mod_forum_digests", enabled: [])

    private static func loaded(_ site: Site) async -> MoodleNotificationSettings {
        let settings = MoodleNotificationSettings(signIn: testSignIn, api: site.api)
        await settings.load()
        return settings
    }

    private static func shown(_ key: String, in settings: MoodleNotificationSettings) throws -> MoodleNotificationMatrix.Preference {
        try #require(settings.matrix?.preference(key))
    }

    @Test("a switch moves at once and every switch stays off until the write and its reload end")
    func oneWriteAtATime() async throws {
        let gate = ManualSleeper()
        let site = Site(Fixtures.matrix([Self.forum, Self.digest]), gate: gate)
        let settings = await Self.loaded(site)
        settings.method = "email"

        let write = try #require(settings.set(true, for: Self.forum.key))

        #expect(settings.isOn(try Self.shown(Self.forum.key, in: settings)))
        #expect(!settings.canChange(Self.digest))
        #expect(settings.set(true, for: Self.digest.key) == nil)
        try await gate.waitUntilArmed()
        await gate.fire()
        await write.value

        #expect(site.saves == [Self.forum.setting("email", on: true)])
        #expect(settings.canChange(Self.digest))
    }

    @Test("after a write the page shows what the server holds")
    func reloadsAfterWrite() async throws {
        let serverSide = Fixtures.matrix([Self.forum.setting("email", on: true), Self.digest.setting("popup", on: true)])
        let site = Site(Fixtures.matrix([Self.forum, Self.digest]), afterWrite: serverSide)
        let settings = await Self.loaded(site)

        await settings.set(false, for: Self.forum.key)?.value

        #expect(site.loads == 2)
        #expect(settings.matrix == serverSide)
    }

    @Test("a failed write puts the switch back and says why")
    func failedWriteReverts() async throws {
        let failure = MoodleWebserviceError.malformedResponse(detail: "nopermission")
        let site = Site(Fixtures.matrix([Self.forum]), failure: failure)
        let settings = await Self.loaded(site)

        await settings.set(false, for: Self.forum.key)?.value

        #expect(settings.isOn(try Self.shown(Self.forum.key, in: settings)))
        #expect(settings.saveFailure == MoodleFailure.message(for: failure))
        #expect(site.loads == 1)
        #expect(settings.canChange(Self.forum))
    }

    @Test("a load while a write runs sends no read of its own, and the write's read shows the server")
    func loadWaitsOutTheWrite() async throws {
        let gate = ManualSleeper()
        let site = Site(Fixtures.matrix([Self.forum]), gate: gate)
        let settings = await Self.loaded(site)
        let write = try #require(settings.set(false, for: Self.forum.key))
        try await gate.waitUntilArmed()

        await settings.load()

        #expect(site.loads == 1)
        await gate.fire()
        await write.value
        #expect(site.loads == 2)
        #expect(!settings.isOn(try Self.shown(Self.forum.key, in: settings)))
    }

    @Test("a load failure keeps the error for the page and shows no list")
    func loadFailure() async {
        let api = MoodleNotificationAPI(
            load: { throw MoodleWebserviceError.transientNetwork(underlying: "offline") }, save: { _, _ in }
        )
        let settings = MoodleNotificationSettings(signIn: testSignIn, api: api)

        await settings.load()

        #expect(settings.matrix == nil)
        #expect(settings.loadFailure as? MoodleWebserviceError == .transientNetwork(underlying: "offline"))
    }

    @Test("a locked switch and every switch under Disable notifications cannot change")
    func lockedAndDisableAll() async throws {
        let locked = Fixtures.preference("moodle_reportbuilderschedule", enabled: ["email"], locked: ["email"])
        let settings = await Self.loaded(Site(Fixtures.matrix([Self.forum, locked])))
        let disabled = await Self.loaded(Site(Fixtures.matrix([Self.forum], disablesAll: true)))

        #expect(settings.canChange(locked))
        settings.method = "email"
        #expect(!settings.canChange(locked))
        #expect(settings.set(false, for: locked.key) == nil)
        #expect(!disabled.canChange(Self.forum))
        #expect(disabled.set(true, for: Self.forum.key) == nil)
    }

    @Test("a write whose sign-in ends while it waits for the Moodle token is not sent")
    func endedSignInSendsNothing() async throws {
        let token = UUID().uuidString
        let site = URL(string: "https://moodle-stub.invalid")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let gate = ManualSleeper()
        let calls = Calls()
        let tokens = MoodleWebserviceClient.TokenSource(
            stored: {
                if calls.next() > 1 { await gate.sleep(for: .seconds(1)) }
                return token
            },
            renew: { _ in token }
        )
        MoodleNotificationPreferencesServiceTests.answer(
            Fixtures.answer, function: MoodleNotificationPreferencesService.readFunction, token: token
        )
        let signedIn = TestSignIn()
        let settings = MoodleNotificationSettings(
            signIn: signedIn.signIn,
            api: .live(chinese: false, tokens: tokens, session: URLSession(configuration: config), siteURL: site)
        )
        await settings.load()
        let preference = try Self.shown("message_provider_mod_assign_assign_notification", in: settings)

        let write = try #require(settings.set(true, for: preference.key))
        try await gate.waitUntilArmed()
        signedIn.signOut()
        await gate.fire()
        await write.value

        #expect(MoodleNotificationPreferencesServiceTests.bodies(
            of: MoodleNotificationPreferencesService.writeFunction, token: token
        ).isEmpty)
        #expect(settings.saveFailure == nil)
    }
}

private final class Calls: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    func next() -> Int { count.withLock { $0 += 1; return $0 } }
}
