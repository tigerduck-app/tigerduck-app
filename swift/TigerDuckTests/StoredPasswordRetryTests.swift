import Defaults
import Foundation
import os
import Testing
import UIKit
@testable import TigerDuck

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
        #expect(retryAt(after: 2, lastAt: nil, now: refused) == refused)
    }
}

@MainActor
@Suite("Trying a refused stored password again", .serialized)
struct StoredPasswordRetryTests {
    nonisolated static let start = Date(timeIntervalSince1970: 2_000_000)

    nonisolated final class Harvests: @unchecked Sendable {
        private let lock = NSLock()
        private var refusalsLeft: Int
        private var made = 0
        let whileOut: @Sendable () async -> Void

        init(refusing: Int, whileOut: @escaping @Sendable () async -> Void = {}) {
            refusalsLeft = refusing
            self.whileOut = whileOut
        }

        func answer() throws -> MoodleTokenService.TokenTriple {
            try lock.withLock {
                made += 1
                guard refusalsLeft == 0 else {
                    refusalsLeft -= 1
                    throw MoodleWebserviceError.ssoLoginRejected(reason: nil)
                }
                return MoodleTokenService.TokenTriple(
                    signature: "", wstoken: "harvested", privatetoken: nil, postedPassword: true
                )
            }
        }

        var count: Int { lock.withLock { made } }
    }

    @MainActor
    final class School {
        enum Answer { case takes, refuses, isOffline, signsOut }

        var sessionIsLive = true
        var answers: [Answer] = []
        var whileWaitingForTheLock: () -> Void = {}
        weak var auth: AuthService?
        private(set) var posts = 0

        /// `forgetting`: an automatic sign-in's yes forgets the refusals, and the retry's leaves them.
        func post(at now: Date, forgetting: Bool) throws -> Bool {
            posts += 1
            switch answers.isEmpty ? .takes : answers.removeFirst() {
            case .takes:
                if forgetting { SSOLoginService.forgetStoredPasswordRefusals() }
                return true
            case .refuses:
                SSOLoginService.noteStoredPasswordRefused(at: now)
                throw SSOLoginError.loginFailed(reason: "帳號或密碼錯誤")
            case .isOffline:
                throw URLError(.notConnectedToInternet)
            case .signsOut:
                auth?.logout()
                return true
            }
        }
    }

    @MainActor
    final class SignOutHook {
        weak var auth: AuthService?

        func signOut() { auth?.logout() }
    }

    @MainActor
    struct Device {
        let auth: AuthService
        let center = NotificationCenter()
        let backend = BackendFixture(signedIn: false)
        let sleeper = ManualSleeper()
        let clock = OSAllocatedUnfairLock(initialState: StoredPasswordRetryTests.start)
        let school = School()
        let harvests: Harvests

        init(
            harvests: Harvests,
            moodleToken: String? = nil,
            retry: ((
                _ studentId: String, _ password: String, _ isCurrent: @escaping @MainActor () -> Bool, _ mayPost: () -> Bool
            ) async throws -> Bool)?
                = nil
        ) {
            self.harvests = harvests
            let (clock, sleeper, school) = (clock, sleeper, school)
            let token = OSAllocatedUnfairLock<String?>(initialState: moodleToken)
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
                harvest: { _, _ in
                    await harvests.whileOut()
                    return try harvests.answer()
                },
                now: { clock.withLock { $0 } }
            )
            auth = AuthService(
                keychainHasCredentials: { false },
                notificationCenter: center,
                moodleTokens: tokens,
                schoolSignIn: { _, _ in true },
                schoolSessionIsLive: { school.sessionIsLive },
                renewSchoolSignIn: { _, _, _ in try school.post(at: clock.withLock { $0 }, forgetting: true) },
                retrySchoolSignIn: retry ?? { _, _, _, mayPost in
                    school.whileWaitingForTheLock()
                    guard mayPost() else { return false }
                    return try school.post(at: clock.withLock { $0 }, forgetting: false)
                },
                endSchoolSession: { _ in },
                now: { clock.withLock { $0 } },
                retrySleep: { await sleeper.sleep(for: $0) }
            )
            school.auth = auth
            auth.authTokenManager = backend.manager
            auth.accountNotifications = DeliveredNotificationsStub()
        }

        func advance(by seconds: TimeInterval) {
            clock.withLock { $0 += seconds }
        }

        func handOnTheWait() {
            center.post(name: SSOLoginService.storedPasswordPostWaits, object: nil)
        }

        func armTheTry() async throws -> Task<Void, Never> {
            handOnTheWait()
            try await sleeper.waitUntilArmed()
            return try #require(auth.storedPasswordRetry)
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

    static func signedIn(refusals count: Int, last: Date?, _ body: (MemoryKeychain) async throws -> Void) async throws {
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

        try await Self.signedIn(refusals: 0, last: nil) { _ in
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
        let device = Device(harvests: Harvests(refusing: 1))
        device.school.answers = [.refuses]

        try await Self.signedIn(refusals: 0, last: nil) { _ in
            await device.auth.ensureBackendSignedIn()
            let firstTry = try await device.armTheTry()
            device.advance(by: 10)
            await device.sleeper.fire()
            await firstTry.value
            #expect(SSOLoginService.storedPasswordRefusals.count == 2)

            device.handOnTheWait()
            try await device.sleeper.waitUntilArmed(atLeast: 2)
            #expect(await device.sleeper.requestedDurations == [.seconds(10), .seconds(60)])
        }

        #expect(device.school.posts == 1)
        #expect(device.harvests.count == 1)
        #expect(SettingsAPIStub.requests(for: device.backend.loginURL).isEmpty)
    }

    @Test("a try with the school session gone signs in to the school, then harvests the token and signs in to the backend")
    func goneSchoolSessionIsRenewedFirst() async throws {
        let device = Device(harvests: Harvests(refusing: 0))
        device.school.sessionIsLive = false
        device.answerTheBackendSignIn()

        try await Self.signedIn(refusals: 1, last: Self.start) { _ in
            _ = try await device.armTheTry()
            device.advance(by: 10)
            await device.sleeper.fire()
            try await waitUntil { device.isSignedInToTheBackend }
            #expect(SSOLoginService.storedPasswordRefusals.count == 0)
        }

        #expect(device.school.posts == 1)
        #expect(device.harvests.count == 1)
    }

    /// A refusal from Moodle's token sign-in leaves the school session warm, and a warm session
    /// says nothing about the password: only the school's answer to a post does.
    @Test("a try past a warm school session posts the stored password, and the school's yes clears the refusal")
    func warmSchoolSessionStillGetsThePost() async throws {
        let device = Device(harvests: Harvests(refusing: 0), moodleToken: "stored")
        device.school.sessionIsLive = true
        device.answerTheBackendSignIn()

        try await Self.signedIn(refusals: 1, last: Self.start) { _ in
            _ = try await device.armTheTry()
            device.advance(by: 10)
            await device.sleeper.fire()
            try await waitUntil { device.isSignedInToTheBackend }
            #expect(SSOLoginService.storedPasswordRefusals.count == 0)
        }

        #expect(device.school.posts == 1)
        #expect(device.harvests.count == 0)
        #expect(try device.backend.sentMoodleTokens() == ["stored"])
    }

    @Test("a try that signs in to the school clears the banner a failed automatic sign-in left, and nothing of the sheet's",
          arguments: [true, false])
    func signedInTryClearsTheBanner(sessionIsLive: Bool) async throws {
        let device = Device(harvests: Harvests(refusing: 0))
        device.school.sessionIsLive = sessionIsLive
        device.answerTheBackendSignIn()
        device.auth.reauthErrorMessage = "automatic sign-in failed"
        device.auth.loginError = "typed earlier"

        try await Self.signedIn(refusals: 1, last: Self.start) { _ in
            _ = try await device.armTheTry()
            device.advance(by: 10)
            await device.sleeper.fire()
            try await waitUntil { device.isSignedInToTheBackend }
        }

        #expect(device.auth.reauthErrorMessage == nil)
        #expect(device.auth.loginError == "typed earlier")
        #expect(!device.auth.isLoggingIn)
    }

    @Test("a try whose school sign-in is refused stops there, and leaves the sign-in sheet and the banners alone")
    func refusedSchoolSignInStopsTheTry() async throws {
        let device = Device(harvests: Harvests(refusing: 0))
        device.school.sessionIsLive = false
        device.school.answers = [.refuses]

        try await Self.signedIn(refusals: 1, last: Self.start) { _ in
            let waiting = try await device.armTheTry()
            device.advance(by: 10)
            await device.sleeper.fire()
            await waiting.value

            #expect(SSOLoginService.storedPasswordRefusals.count == 2)
            #expect(!device.auth.isLoggingIn)
            #expect(device.auth.loginError == nil)
            #expect(device.auth.reauthErrorMessage == nil)
        }

        #expect(device.school.posts == 1)
        #expect(device.harvests.count == 0)
        #expect(SettingsAPIStub.requests(for: device.backend.loginURL).isEmpty)
        #expect(await device.sleeper.armedCount == 1)
    }

    @Test("a sign-in typed while a try waits for the SSO lock keeps the sheet's state, and the try posts nothing")
    func typedSignInWhileTheTryWaitsKeepsTheSheet() async throws {
        let device = Device(harvests: Harvests(refusing: 0))
        device.school.whileWaitingForTheLock = {
            device.auth.isLoggingIn = true
            device.auth.loginError = "typed"
        }

        try await Self.signedIn(refusals: 1, last: Self.start) { _ in
            let waiting = try await device.armTheTry()
            device.advance(by: 10)
            await device.sleeper.fire()
            await waiting.value

            #expect(device.auth.isLoggingIn)
            #expect(device.auth.loginError == "typed")
            try await device.sleeper.waitUntilArmed(atLeast: 2)
            #expect(await device.sleeper.requestedDurations == [.seconds(10), .seconds(60)])
        }

        #expect(device.school.posts == 0)
        #expect(device.harvests.count == 0)
    }

    @Test("a try lost to the network is armed again a step further down the schedule, and goes through then")
    func offlineTryIsArmedAgain() async throws {
        let device = Device(harvests: Harvests(refusing: 0))
        device.school.sessionIsLive = false
        device.school.answers = [.isOffline, .takes]
        device.answerTheBackendSignIn()

        try await Self.signedIn(refusals: 1, last: Self.start) { _ in
            let first = try await device.armTheTry()
            device.advance(by: 10)
            await device.sleeper.fire()
            await first.value
            try await device.sleeper.waitUntilArmed(atLeast: 2)
            #expect(await device.sleeper.requestedDurations == [.seconds(10), .seconds(60)])
            #expect(SSOLoginService.storedPasswordRefusals.count == 1)

            device.advance(by: 60)
            await device.sleeper.fire()
            try await waitUntil { device.isSignedInToTheBackend }
        }

        #expect(device.school.posts == 2)
        #expect(device.harvests.count == 1)
    }

    enum SignOutStep: String, CaseIterable, CustomTestStringConvertible {
        case schoolSignIn
        case tokenHarvest

        var testDescription: String { rawValue }
    }

    @Test("a sign-out that lands while a try is out stops it before its next step", arguments: SignOutStep.allCases)
    func signOutMidTryStopsIt(step: SignOutStep) async throws {
        let hook = SignOutHook()
        let device = Device(harvests: Harvests(refusing: 0, whileOut: { if step == .tokenHarvest { await hook.signOut() } }))
        hook.auth = device.auth
        device.school.answers = step == .schoolSignIn ? [.signsOut] : []
        device.answerTheBackendSignIn()

        try await Self.signedIn(refusals: 1, last: Self.start) { _ in
            let waiting = try await device.armTheTry()
            device.advance(by: 10)
            await device.sleeper.fire()
            await waiting.value
            #expect(SSOLoginService.storedPasswordRefusals.count == 0)
        }

        #expect(device.harvests.count == (step == .tokenHarvest ? 1 : 0))
        #expect(SettingsAPIStub.requests(for: device.backend.loginURL).isEmpty)
        #expect(await device.sleeper.armedCount == 1)
    }

    @Test("after a relaunch, the first automatic sign-in held back arms the try for what is left of its wait")
    func relaunchArmsTheRestOfTheWait() async throws {
        let device = Device(harvests: Harvests(refusing: 0))
        device.answerTheBackendSignIn()

        try await Self.signedIn(refusals: 2, last: Self.start.addingTimeInterval(-20)) { _ in
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

    @Test("a device the latch held gets a backend session at the first return to the app after the update")
    func latchedDeviceSignsInAfterTheUpdate() async throws {
        let device = Device(harvests: Harvests(refusing: 0))
        device.answerTheBackendSignIn()

        try await Self.signedIn(refusals: 0, last: nil) { _ in
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
        var retryTimes: [Date] = []
    }

    @Test("a refusal and each automatic post it holds back are announced with when the next post may go")
    func waitsAreAnnounced() async throws {
        let refused = Date(timeIntervalSince1970: 3_000_000 + Double(Int.random(in: 0..<1_000_000)))
        let retryAt = refused.addingTimeInterval(SSOLoginService.storedPasswordRetryDelay(afterRefusals: 1))
        try await Self.signedIn(refusals: 0, last: nil) { _ in
            let heard = Announcements()
            let observer = NotificationCenter.default.addObserver(
                forName: SSOLoginService.storedPasswordPostWaits, object: nil, queue: .main
            ) { note in
                guard let at = note.userInfo?[SSOLoginService.storedPasswordRetryAtKey] as? Date else { return }
                MainActor.assumeIsolated { heard.retryTimes.append(at) }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            SSOLoginService.noteStoredPasswordRefused(at: refused)
            try await waitUntil { heard.retryTimes.contains(retryAt) }
            #expect(SSOLoginService.storedPasswordPostMustWait(now: refused.addingTimeInterval(1)))
            try await waitUntil { heard.retryTimes.filter { $0 == retryAt }.count == 2 }
        }
    }

    @Test("a sign-out while a try waits drops the try and clears the refusals")
    func signOutDropsTheWaitingTry() async throws {
        let device = Device(harvests: Harvests(refusing: 0))

        try await Self.signedIn(refusals: 1, last: Self.start) { keychain in
            let waiting = try await device.armTheTry()

            device.auth.logout()
            #expect(SSOLoginService.storedPasswordRefusals.count == 0)
            keychain.unlock(withMoodleToken: false)
            SSOLoginService.storedPasswordRefusals = (1, Self.start)
            device.advance(by: 10)
            await device.sleeper.fire()
            await waiting.value
        }

        #expect(device.auth.storedPasswordRetry == nil)
        #expect(device.school.posts == 0)
        #expect(device.harvests.count == 0)
    }

    @Test("a try that comes while a sign-in is under way leaves it alone, and comes again a step later")
    func tryWhileASignInRunsLeavesItAlone() async throws {
        let device = Device(harvests: Harvests(refusing: 0))

        try await Self.signedIn(refusals: 1, last: Self.start) { _ in
            let waiting = try await device.armTheTry()

            device.auth.isLoggingIn = true
            device.advance(by: 10)
            await device.sleeper.fire()
            await waiting.value
            #expect(device.auth.isLoggingIn)
            try await device.sleeper.waitUntilArmed(atLeast: 2)
            #expect(await device.sleeper.requestedDurations == [.seconds(10), .seconds(60)])
        }

        #expect(device.school.posts == 0)
        #expect(device.harvests.count == 0)
    }

    @Test("a try that finds the refusals cleared, as a sign-in the user typed leaves them, sends nothing")
    func tryAfterATypedSignInSendsNothing() async throws {
        let device = Device(harvests: Harvests(refusing: 0))

        try await Self.signedIn(refusals: 1, last: Self.start) { _ in
            let waiting = try await device.armTheTry()

            SSOLoginService.forgetStoredPasswordRefusals()
            device.advance(by: 10)
            await device.sleeper.fire()
            await waiting.value
        }

        #expect(device.school.posts == 0)
        #expect(device.harvests.count == 0)
        #expect(await device.sleeper.armedCount == 1)
    }
}
