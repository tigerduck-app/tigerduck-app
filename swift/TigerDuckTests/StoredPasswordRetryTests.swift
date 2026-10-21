// The tries of a stored password the school refused, against stand-ins for the school, Moodle and
// the backend. The refusals are real `Defaults` keys, so each test that touches them holds the gate
// in docs/decisions/0020-real-defaults-gate.md and puts them back.
import Defaults
import Foundation
import os
import Testing
import UIKit
@testable import TigerDuck

/// The waits a refusal of the stored password starts
/// (https://github.com/tigerduck-app/tigerduck-app/issues/768).
@Suite("The waits after a refused stored password")
struct StoredPasswordScheduleTests {
    @Test("after refusals in a row the waits are ten seconds, a minute and five minutes, then six hours")
    func waitsGrowToSixHours() {
        let waits = (1...6).map { SSOLoginService.storedPasswordRetryDelay(afterRefusals: $0) }
        let sixHours: TimeInterval = 6 * 60 * 60
        let expected: [TimeInterval] = [10, 60, 300, sixHours, sixHours, sixHours]
        #expect(waits == expected)
    }

    @Test("the next try is due a wait after the last refusal, and at once once the clock was set back")
    func nextTryIsMeasuredFromTheLastRefusal() {
        let refused = Date(timeIntervalSince1970: 1_000_000)
        func retryAt(after refusals: Int, lastAt last: Date?, now: Date) -> Date? {
            SSOLoginService.storedPasswordRetryAt(refusals: refusals, lastRefusal: last, now: now)
        }
        #expect(retryAt(after: 0, lastAt: nil, now: refused) == nil)
        #expect(retryAt(after: 1, lastAt: refused, now: refused) == refused.addingTimeInterval(10))
        #expect(retryAt(after: 4, lastAt: refused, now: refused.addingTimeInterval(60))
            == refused.addingTimeInterval(SSOLoginService.storedPasswordRetryInterval))
        let setBack = refused.addingTimeInterval(-1)
        #expect(retryAt(after: 4, lastAt: refused, now: setBack) == setBack)
        // A count without its time, as a write cut short could leave, holds nothing back.
        #expect(retryAt(after: 2, lastAt: nil, now: refused) == refused)
    }
}

/// `AuthService`'s tries of a refused stored password, armed on a `ManualSleeper` and timed by the
/// test's clock (https://github.com/tigerduck-app/tigerduck-app/issues/768).
@MainActor
@Suite("Trying a refused stored password again", .serialized)
struct StoredPasswordRetryTests {
    nonisolated static let start = Date(timeIntervalSince1970: 2_000_000)

    /// Moodle's answers to the harvests: the first `refusing` refuse the stored password, and each
    /// after them hands out "harvested".
    nonisolated final class Harvests: @unchecked Sendable {
        private let lock = NSLock()
        private var refusalsLeft: Int
        private var made = 0

        init(refusing: Int) { refusalsLeft = refusing }

        func answer() throws -> MoodleTokenService.TokenTriple {
            try lock.withLock {
                made += 1
                guard refusalsLeft == 0 else {
                    refusalsLeft -= 1
                    throw MoodleWebserviceError.ssoLoginRejected(reason: nil)
                }
                return MoodleTokenService.TokenTriple(signature: "", wstoken: "harvested", privatetoken: nil)
            }
        }

        var count: Int { lock.withLock { made } }
    }

    @MainActor
    final class ProbeCount {
        var count = 0
    }

    /// A device signed in to the school, whose SSO session is live, with no Moodle token and no
    /// backend session.
    @MainActor
    struct Device {
        let auth: AuthService
        let center = NotificationCenter()
        let backend = BackendFixture(signedIn: false)
        let sleeper = ManualSleeper()
        let clock = OSAllocatedUnfairLock(initialState: StoredPasswordRetryTests.start)
        let probes = ProbeCount()
        let harvests: Harvests

        init(harvests: Harvests) {
            self.harvests = harvests
            let (clock, sleeper, probes) = (clock, sleeper, probes)
            let token = OSAllocatedUnfairLock<String?>(initialState: nil)
            let tokens = MoodleTokenService(
                storedCredentials: {
                    guard let studentId = KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId),
                          let password = KeychainManager.loadString(key: AppConstants.KeychainKeys.password) else {
                        return nil
                    }
                    return (studentId, password)
                },
                tokens: .init(
                    load: { token.withLock { $0 } },
                    save: { triple in token.withLock { $0 = triple.wstoken } },
                    drop: { token.withLock { $0 = nil } }
                ),
                harvest: { _, _ in try harvests.answer() },
                now: { clock.withLock { $0 } }
            )
            auth = AuthService(
                keychainHasCredentials: { false },
                notificationCenter: center,
                moodleTokens: tokens,
                schoolSignIn: { _, _ in true },
                schoolSessionIsLive: {
                    probes.count += 1
                    return true
                },
                renewSchoolSignIn: { _, _, _ in
                    Issue.record("the SSO session is live, so nothing renews it")
                    return false
                },
                endSchoolSession: { _ in },
                now: { clock.withLock { $0 } },
                retrySleep: { await sleeper.sleep(for: $0) }
            )
            auth.authTokenManager = backend.manager
            auth.accountNotifications = DeliveredNotificationsStub()
        }

        func advance(by seconds: TimeInterval) {
            clock.withLock { $0 += seconds }
        }

        /// What the app's center does with the wait `SSOLoginService` announces on the default one.
        func handOnTheWait() {
            center.post(name: SSOLoginService.storedPasswordPostWaits, object: nil)
        }

        func returnToTheApp() {
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        }

        var isSignedInToTheBackend: Bool {
            backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R9"
        }

        func answerTheBackendSignIn() {
            SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)
        }
    }

    /// Runs `body` signed in on a keychain of its own, after `count` refusals of the stored password,
    /// the last at `last`, and puts back the real keys that sign-ins and sign-outs write.
    func signedIn(refusals count: Int, last: Date?, _ body: (MemoryKeychain) async throws -> Void) async throws {
        try await withExclusiveRealDefaults {
            let saved = (
                SSOLoginService.storedPasswordRefusals, Defaults[.ssoLoginTimestamp], Defaults[.ntustCredentialsPresent]
            )
            SSOLoginService.storedPasswordRefusals = (count, last)
            defer {
                (SSOLoginService.storedPasswordRefusals, Defaults[.ssoLoginTimestamp], Defaults[.ntustCredentialsPresent])
                    = saved
            }
            let keychain = MemoryKeychain.signedIn(withMoodleToken: false)
            try await SecureStore.$sharedForTesting.withValue(keychain) { try await body(keychain) }
        }
    }

    @Test("a refused harvest is tried again ten seconds later, and a try the school takes signs in to the backend")
    func refusalThenAcceptedTrySignsIn() async throws {
        let device = Device(harvests: Harvests(refusing: 1))
        device.answerTheBackendSignIn()

        try await signedIn(refusals: 0, last: nil) { _ in
            await device.auth.ensureBackendSignedIn()
            #expect(SSOLoginService.storedPasswordRefusals.count == 1)
            device.handOnTheWait()
            try await device.sleeper.waitUntilArmed()
            #expect(await device.sleeper.requestedDurations == [.seconds(10)])

            device.advance(by: 10)
            await device.sleeper.fire()
            try await waitUntil { device.isSignedInToTheBackend }
            #expect(SSOLoginService.storedPasswordRefusals.count == 0)
        }

        #expect(device.harvests.count == 2)
        #expect(try device.backend.sentMoodleTokens() == ["harvested"])
    }

    @Test("a try the school refuses again arms the next for a minute later")
    func refusedTryArmsTheNextWait() async throws {
        let device = Device(harvests: Harvests(refusing: 2))

        try await signedIn(refusals: 0, last: nil) { _ in
            await device.auth.ensureBackendSignedIn()
            device.handOnTheWait()
            try await device.sleeper.waitUntilArmed()
            let firstTry = try #require(device.auth.storedPasswordRetry)
            device.advance(by: 10)
            await device.sleeper.fire()
            await firstTry.value
            #expect(SSOLoginService.storedPasswordRefusals.count == 2)

            device.handOnTheWait()
            try await device.sleeper.waitUntilArmed(atLeast: 2)
            #expect(await device.sleeper.requestedDurations == [.seconds(10), .seconds(60)])
        }

        #expect(device.harvests.count == 2)
        #expect(SettingsAPIStub.requests(for: device.backend.loginURL).isEmpty)
    }

    @Test("after a relaunch, the first automatic sign-in held back arms the try for what is left of its wait")
    func relaunchArmsTheRestOfTheWait() async throws {
        let device = Device(harvests: Harvests(refusing: 0))
        device.answerTheBackendSignIn()

        // Two refusals before the relaunch, the last 20 seconds before it: 40 seconds of the minute are left.
        try await signedIn(refusals: 2, last: Self.start.addingTimeInterval(-20)) { _ in
            await device.auth.ensureBackendSignedIn()
            #expect(device.harvests.count == 0)
            device.handOnTheWait()
            try await device.sleeper.waitUntilArmed()
            #expect(await device.sleeper.requestedDurations == [.seconds(40)])

            device.advance(by: 40)
            await device.sleeper.fire()
            try await waitUntil { device.isSignedInToTheBackend }
        }

        #expect(device.harvests.count == 1)
        #expect(SettingsAPIStub.requests(for: device.backend.loginURL).count == 1)
    }

    /// The device of the issue: signed in, its backend session revoked, no Moodle token stored and
    /// the latch of 2.6.2 up.
    @Test("a device the latch held gets a backend session at the first return to the app after the update")
    func latchedDeviceSignsInAfterTheUpdate() async throws {
        let device = Device(harvests: Harvests(refusing: 0))
        device.answerTheBackendSignIn()

        try await signedIn(refusals: 0, last: nil) { _ in
            try await StoredPasswordLatchRetryMigrationTests.withLatch(true) {
                StoredPasswordLatchRetryMigration.runIfNeeded()
                device.returnToTheApp()
                try await waitUntil { device.isSignedInToTheBackend }
                #expect(SSOLoginService.storedPasswordRefusals.count == 0)
            }
        }

        #expect(device.harvests.count == 1)
        #expect(SettingsAPIStub.requests(for: device.backend.loginURL).count == 1)
        #expect(await device.sleeper.armedCount == 0)
    }

    @MainActor
    final class Announcements {
        var count = 0
    }

    @Test("a refusal and each automatic post it holds back are announced, so a try can be armed")
    func waitsAreAnnounced() async throws {
        try await signedIn(refusals: 0, last: nil) { _ in
            let heard = Announcements()
            let observer = NotificationCenter.default.addObserver(
                forName: SSOLoginService.storedPasswordPostWaits, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { heard.count += 1 }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            SSOLoginService.noteStoredPasswordRefused()
            try await waitUntil { heard.count >= 1 }
            let afterTheRefusal = heard.count
            #expect(SSOLoginService.storedPasswordPostMustWait())
            try await waitUntil { heard.count > afterTheRefusal }
        }
    }

    @Test("a sign-out while a try waits drops the try and clears the refusals")
    func signOutDropsTheWaitingTry() async throws {
        let device = Device(harvests: Harvests(refusing: 0))

        try await signedIn(refusals: 1, last: Self.start) { keychain in
            device.handOnTheWait()
            try await device.sleeper.waitUntilArmed()
            let waiting = try #require(device.auth.storedPasswordRetry)

            device.auth.logout()
            #expect(SSOLoginService.storedPasswordRefusals.count == 0)
            // The next account signs in and is refused in turn, which the dropped try must not answer.
            keychain.unlock(withMoodleToken: false)
            SSOLoginService.storedPasswordRefusals = (1, Self.start)
            device.advance(by: 10)
            await device.sleeper.fire()
            await waiting.value
        }

        #expect(device.auth.storedPasswordRetry == nil)
        #expect(device.probes.count == 0)
        #expect(device.harvests.count == 0)
    }

    @Test("a try that finds the refusals cleared, as a sign-in the user typed leaves them, sends nothing")
    func tryAfterATypedSignInSendsNothing() async throws {
        let device = Device(harvests: Harvests(refusing: 0))

        try await signedIn(refusals: 1, last: Self.start) { _ in
            device.handOnTheWait()
            try await device.sleeper.waitUntilArmed()
            let waiting = try #require(device.auth.storedPasswordRetry)

            SSOLoginService.forgetStoredPasswordRefusals()
            device.advance(by: 10)
            await device.sleeper.fire()
            await waiting.value
        }

        #expect(device.probes.count == 0)
        #expect(device.harvests.count == 0)
    }
}
