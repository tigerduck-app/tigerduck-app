// `AuthTokenManager` and `AuthService` through `SettingsAPIStub`. The backend rotates the refresh
// token on every refresh, redeems the old one once more within 60 s, and takes any later reuse for
// theft (https://github.com/tigerduck-app/tigerduck-app/issues/375).
import Defaults
import Foundation
import Testing
import UIKit
import Valet
import os
@testable import TigerDuck

@Suite("Backend token refresh")
struct BackendTokenRefreshTests {
    @Test("a refresh whose reply is lost is sent once more with the same token and keeps that pair")
    func lostReplyIsRetriedWithTheSameToken() async throws {
        let backend = BackendFixture()
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A2", refresh: "R2"), for: backend.refreshURL)

        #expect(await backend.manager.validAccessToken() == "A2")

        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R2")
        #expect(backend.recorder.stored(AuthTokenManager.accessTokenKey) == "A2")
        #expect(await backend.manager.validAccessToken() == "A2")
        #expect(SettingsAPIStub.requests(for: backend.refreshURL).count == 2)
    }

    @Test("a retry whose reply is lost too is not sent again, and the old pair stays")
    func secondLostReplyGivesUp() async throws {
        let backend = BackendFixture()
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A3", refresh: "R3"), for: backend.refreshURL)

        #expect(await backend.manager.validAccessToken() == nil)

        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R0")
        #expect(await backend.manager.isLoggedIn)
        #expect(await backend.manager.validAccessToken() == "A3")
        #expect(try backend.sentRefreshTokens() == ["R0", "R0", "R0"])
    }

    @Test("a refresh request gives up well inside the backend's 60 s reuse grace")
    func refreshTimesOutInsideTheGrace() async throws {
        let backend = BackendFixture()
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A2", refresh: "R2"), for: backend.refreshURL)

        _ = await backend.manager.validAccessToken()

        let request = try #require(SettingsAPIStub.requests(for: backend.refreshURL).first)
        #expect(request.timeoutInterval == 20)
    }

    @Test("a 429 or a 5xx keeps the session and asks for no relogin", arguments: [429, 500, 503])
    func transientStatusKeepsTheSession(status: Int) async throws {
        let backend = BackendFixture()
        let relogins = CallCount()
        await backend.manager.setRefreshFailedHandler {
            relogins.increment()
            return false
        }
        SettingsAPIStub.enqueue(.init(statusCode: status, body: Data(#"{"detail":"x"}"#.utf8)), for: backend.refreshURL)

        #expect(await backend.manager.validAccessToken() == nil)

        #expect(relogins.value == 0)
        #expect(await backend.manager.isLoggedIn)
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R0")
        // An answer, even an error, is no lost reply, so nothing is sent again.
        #expect(SettingsAPIStub.requests(for: backend.refreshURL).count == 1)
    }

    @Test("another 4xx asks for a relogin and keeps the token when that fails", arguments: [400, 403, 404, 422])
    func rejectedTokenIsKeptWhenTheReloginFails(status: Int) async throws {
        let backend = BackendFixture()
        let relogins = CallCount()
        await backend.manager.setRefreshFailedHandler {
            relogins.increment()
            return false
        }
        SettingsAPIStub.enqueue(.init(statusCode: status, body: Data(#"{"detail":"x"}"#.utf8)), for: backend.refreshURL)

        #expect(await backend.manager.validAccessToken() == nil)

        #expect(relogins.value == 1)
        #expect(await backend.manager.isLoggedIn)
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R0")
        #expect(SettingsAPIStub.requests(for: backend.refreshURL).count == 1)
    }

    @Test("a token the backend turns down with a 422 gives way to the relogin's session")
    func rejectedTokenIsReplacedByTheRelogin() async throws {
        let backend = BackendFixture()
        let manager = backend.manager
        await manager.setRefreshFailedHandler {
            (try? await manager.login(
                studentId: "B11000000", moodleToken: "moodle-token",
                moodlePrivateToken: nil, platform: "ios"
            )) != nil
        }
        SettingsAPIStub.enqueue(.init(statusCode: 422, body: Data(#"{"detail":"x"}"#.utf8)), for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)

        #expect(await manager.validAccessToken() == "A9")

        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R9")
    }

    @Test("a 401 signs in again and goes on with the new session")
    func unauthorizedRelogsIn() async throws {
        let backend = BackendFixture()
        let manager = backend.manager
        await manager.setRefreshFailedHandler {
            (try? await manager.login(
                studentId: "B11000000", moodleToken: "moodle-token",
                moodlePrivateToken: nil, platform: "ios"
            )) != nil
        }
        SettingsAPIStub.enqueue(BackendFixture.reuseDetected, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)

        #expect(await manager.validAccessToken() == "A9")

        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R9")
        #expect(SettingsAPIStub.requests(for: backend.refreshURL).count == 1)
    }

    @Test("a 401 whose relogin fails signs out of the backend")
    func unauthorizedWithoutReloginSignsOut() async throws {
        let backend = BackendFixture()
        await backend.manager.setRefreshFailedHandler { false }
        SettingsAPIStub.enqueue(BackendFixture.reuseDetected, for: backend.refreshURL)

        #expect(await backend.manager.validAccessToken() == nil)

        #expect(await !backend.manager.isLoggedIn)
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == nil)
    }

    @Test("a login whose reply comes back after a sign-out stores nothing")
    func loginAfterSignOutStoresNothing() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture(signedIn: false)
        let manager = backend.manager
        SettingsAPIStub.enqueue(
            BackendFixture.loginReply(access: "A9", refresh: "R9", heldBy: gate), for: backend.loginURL
        )
        let login = Task {
            try await manager.login(
                studentId: "B11000000", moodleToken: "moodle-token",
                moodlePrivateToken: nil, platform: "ios"
            )
        }
        try await waitUntil { SettingsAPIStub.requests(for: backend.loginURL).count == 1 }

        await manager.logout()
        gate.open()

        await #expect(throws: CancellationError.self) { try await login.value }
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == nil)
        #expect(await !manager.isLoggedIn)
    }

    @Test("a refresh whose reply comes back after a sign-out stores nothing")
    func refreshAfterSignOutStoresNothing() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        let manager = backend.manager
        SettingsAPIStub.enqueue(
            BackendFixture.refreshReply(access: "A2", refresh: "R2", heldBy: gate), for: backend.refreshURL
        )
        let refresh = Task { await manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        await manager.logout()
        gate.open()

        #expect(await refresh.value == nil)
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == nil)
        #expect(await !manager.isLoggedIn)
    }

    @Test("a refresh whose reply is lost after a sign-out is not sent again")
    func lostReplyAfterSignOutIsNotRetried() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        let manager = backend.manager
        var lost = SettingsAPIStub.StubResponse.noReply
        lost.gate = gate
        SettingsAPIStub.enqueue(lost, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A2", refresh: "R2"), for: backend.refreshURL)
        let refresh = Task { await manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        await manager.logout()
        gate.open()

        #expect(await refresh.value == nil)
        #expect(SettingsAPIStub.requests(for: backend.refreshURL).count == 1)
    }

    /// The replies a refresh gets, in order.
    enum Outcome: String, CaseIterable, CustomTestStringConvertible {
        case success, lostThenSuccess, lostTwice, serverError, unauthorized

        var replies: [SettingsAPIStub.StubResponse] {
            let pair = BackendFixture.refreshReply(access: "A2", refresh: "R2")
            switch self {
            case .success: return [pair]
            case .lostThenSuccess: return [.noReply, pair]
            case .lostTwice: return [.noReply, .noReply]
            case .serverError: return [.init(statusCode: 503, body: Data())]
            case .unauthorized: return [BackendFixture.reuseDetected]
            }
        }

        var testDescription: String { rawValue }
    }

    @Test("the background task runs from the first request until the tokens are written", arguments: Outcome.allCases)
    func backgroundTaskCoversTheRefresh(outcome: Outcome) async throws {
        let backend = BackendFixture()
        let manager = backend.manager
        await manager.setRefreshFailedHandler {
            (try? await manager.login(
                studentId: "B11000000", moodleToken: "moodle-token",
                moodlePrivateToken: nil, platform: "ios"
            )) != nil
        }
        for reply in outcome.replies {
            SettingsAPIStub.enqueue(reply, for: backend.refreshURL)
        }
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)

        _ = await manager.validAccessToken()

        let tasks = backend.recorder.backgroundTasks
        #expect(tasks.begun == 1)
        #expect(tasks.ended == 1)
        #expect(tasks.requestsAtFirstBegin == 0)
        #expect(backend.recorder.writesOutsideABackgroundTask == 0)
    }
}

@Suite("Backend sign-in")
@MainActor
struct BackendSignInTests {
    @Test("an unlock signs a signed-out backend back in")
    func unlockSignsTheBackendIn() async throws {
        let backend = BackendFixture(signedIn: false)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)
        let center = NotificationCenter()
        let auth = AuthService(keychainHasCredentials: { false }, notificationCenter: center)
        auth.authTokenManager = backend.manager

        try await SecureStore.$sharedForTesting.withValue(MemoryKeychain.signedIn()) {
            center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
            try await waitUntil { backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R9" }
        }

        #expect(SettingsAPIStub.requests(for: backend.loginURL).count == 1)
        withExtendedLifetime(auth) {}
    }

    @Test("an unlock that meets a sign-in ending signed out tries once more")
    func unlockRetriesAfterASignInThatFailed() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture(signedIn: false)
        SettingsAPIStub.enqueue(.init(statusCode: 503, body: Data(), gate: gate), for: backend.loginURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)
        let center = NotificationCenter()
        let auth = AuthService(keychainHasCredentials: { false }, notificationCenter: center)
        auth.authTokenManager = backend.manager

        try await SecureStore.$sharedForTesting.withValue(MemoryKeychain.signedIn()) {
            async let first: Void = auth.ensureBackendSignedIn()
            try await waitUntil { SettingsAPIStub.requests(for: backend.loginURL).count == 1 }
            center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
            gate.open()
            await first
            try await waitUntil { backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R9" }
        }

        #expect(SettingsAPIStub.requests(for: backend.loginURL).count == 2)
        withExtendedLifetime(auth) {}
    }

    @Test("sign-ins that overlap share one login")
    func overlappingSignInsShareOneLogin() async throws {
        let backend = BackendFixture(signedIn: false)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)
        let auth = AuthService(keychainHasCredentials: { false }, notificationCenter: NotificationCenter())
        auth.authTokenManager = backend.manager

        await SecureStore.$sharedForTesting.withValue(MemoryKeychain.signedIn()) {
            async let first: Void = auth.ensureBackendSignedIn()
            async let second: Void = auth.ensureBackendSignedIn()
            _ = await (first, second)
        }

        #expect(SettingsAPIStub.requests(for: backend.loginURL).count == 1)
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R9")
    }

    // MARK: - Signing in again after the backend revoked the session
    // https://github.com/tigerduck-app/tigerduck-app/issues/385

    /// How a test reaches a backend sign-in.
    enum SignInPath: String, CaseIterable, CustomTestStringConvertible {
        /// The relogin after a refresh the backend answers 401.
        case relogin
        /// `ensureBackendSignedIn()` with no session.
        case signIn

        var testDescription: String { rawValue }
    }

    @Test("with no Moodle token stored, a sign-in harvests one and signs in with it", arguments: SignInPath.allCases)
    func signInHarvestsAMissingMoodleToken(path: SignInPath) async throws {
        try await withPasswordLatchCleared {
            let backend = BackendFixture(signedIn: path == .relogin)
            let harvests = CallCount()
            let auth = AuthService(
                keychainHasCredentials: { false }, notificationCenter: NotificationCenter(),
                moodleTokens: .standIn(harvests: harvests)
            )
            auth.authTokenManager = backend.manager
            await backend.manager.setRefreshFailedHandler { await auth.reloginToBackend() }
            if path == .relogin {
                SettingsAPIStub.enqueue(BackendFixture.reuseDetected, for: backend.refreshURL)
            }
            SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)

            await SecureStore.$sharedForTesting.withValue(MemoryKeychain.signedIn(withMoodleToken: false)) {
                switch path {
                case .relogin: _ = await backend.manager.validAccessToken()
                case .signIn: await auth.ensureBackendSignedIn()
                }
            }

            let sent = try backend.sentMoodleTokens()
            #expect(harvests.value == 1)
            #expect(sent == ["harvested"])
            #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R9")
        }
    }

    @Test("a backend sign-in sends the Moodle token and no password", arguments: SignInPath.allCases)
    func backendSignInSendsNoPassword(path: SignInPath) async throws {
        try await withPasswordLatchCleared {
            let backend = BackendFixture(signedIn: path == .relogin)
            let auth = AuthService(
                keychainHasCredentials: { false }, notificationCenter: NotificationCenter(),
                moodleTokens: .standIn(harvests: CallCount())
            )
            auth.authTokenManager = backend.manager
            await backend.manager.setRefreshFailedHandler { await auth.reloginToBackend() }
            if path == .relogin {
                SettingsAPIStub.enqueue(BackendFixture.reuseDetected, for: backend.refreshURL)
            }
            SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)

            await SecureStore.$sharedForTesting.withValue(MemoryKeychain.signedIn()) {
                switch path {
                case .relogin: _ = await backend.manager.validAccessToken()
                case .signIn: await auth.ensureBackendSignedIn()
                }
            }

            let bodies = try backend.sentLoginBodies()
            #expect(bodies.count == 1)
            #expect(bodies.allSatisfy { $0["password"] == nil })
            #expect(bodies.allSatisfy { $0["moodle_token"] is String })
        }
    }

    @Test("behind a locked screen a relogin harvests nothing and sends nothing")
    func lockedReloginSendsNothing() async throws {
        let backend = BackendFixture()
        let harvests = CallCount()
        let auth = AuthService(
            keychainHasCredentials: { false }, notificationCenter: NotificationCenter(),
            moodleTokens: .standIn(harvests: harvests)
        )
        auth.authTokenManager = backend.manager
        await backend.manager.setRefreshFailedHandler { await auth.reloginToBackend() }
        SettingsAPIStub.enqueue(BackendFixture.reuseDetected, for: backend.refreshURL)

        let token = await SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) {
            await backend.manager.validAccessToken()
        }

        #expect(token == nil)
        #expect(harvests.value == 0)
        #expect(SettingsAPIStub.requests(for: backend.loginURL).isEmpty)
    }

    @Test("a return to the app after a relogin that failed signs in again")
    func returnToTheAppSignsInAgain() async throws {
        let backend = BackendFixture()
        let center = NotificationCenter()
        let auth = AuthService(keychainHasCredentials: { false }, notificationCenter: center)
        auth.authTokenManager = backend.manager
        await backend.manager.setRefreshFailedHandler { await auth.reloginToBackend() }
        SettingsAPIStub.enqueue(BackendFixture.reuseDetected, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)
        let keychain = MemoryKeychain.locked()

        try await SecureStore.$sharedForTesting.withValue(keychain) {
            #expect(await backend.manager.validAccessToken() == nil)
            try #require(await !backend.manager.isLoggedIn)

            keychain.unlock()
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            try await waitUntil { backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R9" }
        }

        #expect(SettingsAPIStub.requests(for: backend.loginURL).count == 1)
        withExtendedLifetime(auth) {}
    }

    @Test("an automatic sign-in waits five minutes after one that failed")
    func failedSignInPauses() {
        let failed = Date()
        #expect(AuthService.backendSignInIsDue(lastFailure: nil, now: failed))
        #expect(!AuthService.backendSignInIsDue(lastFailure: failed, now: failed.addingTimeInterval(299)))
        #expect(AuthService.backendSignInIsDue(lastFailure: failed, now: failed.addingTimeInterval(300)))
        #expect(AuthService.backendSignInIsDue(lastFailure: failed, now: failed.addingTimeInterval(-1)))
    }

    @Test("after a sign-in that failed, the next one sends nothing")
    func failedSignInHoldsOffTheNext() async throws {
        let backend = BackendFixture(signedIn: false)
        let auth = AuthService(keychainHasCredentials: { false }, notificationCenter: NotificationCenter())
        auth.authTokenManager = backend.manager
        SettingsAPIStub.enqueue(.init(statusCode: 503, body: Data()), for: backend.loginURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)

        await SecureStore.$sharedForTesting.withValue(MemoryKeychain.signedIn()) {
            await auth.ensureBackendSignedIn()
            await auth.ensureBackendSignedIn()
        }

        #expect(SettingsAPIStub.requests(for: backend.loginURL).count == 1)
        #expect(await !backend.manager.isLoggedIn)
    }

    @Test("a registration with no session signs in first and goes out with the new session")
    func registrationWithNoSessionSignsInFirst() async throws {
        try await withNoSyncPreferencesPending {
            let backend = BackendFixture(signedIn: false)
            let auth = AuthService(keychainHasCredentials: { false }, notificationCenter: NotificationCenter())
            auth.authTokenManager = backend.manager
            await backend.manager.setNoSessionHandler { await auth.ensureBackendSignedIn() }
            SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)
            let push = RegistrationFixture(manager: backend.manager)
            push.answerAnnounce()
            push.answerRegister()

            await SecureStore.$sharedForTesting.withValue(MemoryKeychain.signedIn()) {
                await push.register()
            }

            #expect(SettingsAPIStub.requests(for: backend.loginURL).count == 1)
            let registrations = SettingsAPIStub.requests(for: push.registerURL)
            try #require(registrations.count == 1)
            #expect(registrations[0].value(forHTTPHeaderField: "Authorization") == "Bearer A9")
            let announces = SettingsAPIStub.requests(for: push.announceURL)
            #expect(announces.map { $0.value(forHTTPHeaderField: "Authorization") } == [nil])
            #expect(await push.service.snapshot().lastError == nil)
        }
    }

    @Test("a registration that cannot sign in sends nothing without a token and records why")
    func registrationThatCannotSignInSendsNothing() async throws {
        try await withNoSyncPreferencesPending {
            let backend = BackendFixture(signedIn: false)
            let auth = AuthService(keychainHasCredentials: { false }, notificationCenter: NotificationCenter())
            auth.authTokenManager = backend.manager
            await backend.manager.setNoSessionHandler { await auth.ensureBackendSignedIn() }
            SettingsAPIStub.enqueue(.init(statusCode: 503, body: Data()), for: backend.loginURL)
            let push = RegistrationFixture(manager: backend.manager)
            for _ in 0..<4 { push.answerAnnounce() }

            await SecureStore.$sharedForTesting.withValue(MemoryKeychain.signedIn()) {
                await push.register()
            }

            // The first attempt and its three retries each ask for a session. The failed sign-in
            // holds off the later ones, and the announce, which needs none, goes every time.
            #expect(SettingsAPIStub.requests(for: backend.loginURL).count == 1)
            #expect(SettingsAPIStub.requests(for: push.registerURL).isEmpty)
            #expect(SettingsAPIStub.requests(for: push.announceURL).count == 4)
            let reason = PushAPIError.notSignedIn.localizedDescription
            #expect(await push.service.snapshot().lastError == "register: \(reason)")
        }
    }

    @Test("requests that find no session at once share one sign-in")
    func requestsWithNoSessionShareOneSignIn() async throws {
        let backend = BackendFixture(signedIn: false)
        let manager = backend.manager
        let auth = AuthService(keychainHasCredentials: { false }, notificationCenter: NotificationCenter())
        auth.authTokenManager = manager
        await manager.setNoSessionHandler { await auth.ensureBackendSignedIn() }
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)

        let headers = await SecureStore.$sharedForTesting.withValue(MemoryKeychain.signedIn()) {
            async let first = manager.authorizationHeader()
            async let second = manager.authorizationHeader()
            return await [first, second]
        }

        #expect(headers == ["Bearer A9", "Bearer A9"])
        #expect(SettingsAPIStub.requests(for: backend.loginURL).count == 1)
    }

    // MARK: - Asking the user to sign in again
    // https://github.com/tigerduck-app/tigerduck-app/issues/385

    /// The condition of asking to sign in again that a test turns the other way, or none.
    enum SignInAgainCondition: String, CaseIterable, CustomTestStringConvertible {
        case none, syncOff, credentialsUnreadable, backendSignedIn, signingIn, registrationSent

        var testDescription: String { rawValue }
    }

    @Test("the TigerSync status asks to sign in again only while every condition holds",
          arguments: SignInAgainCondition.allCases)
    func signInAgainNeedsEveryCondition(turned: SignInAgainCondition) {
        let asks = AuthService.asksToSignInAgain(
            syncEnabled: turned != .syncOff,
            credentialsReadable: turned != .credentialsUnreadable,
            hasBackendSession: turned == .backendSignedIn,
            signingIn: turned == .signingIn,
            registrationFoundNoSession: turned != .registrationSent
        )

        #expect(asks == (turned == .none))
    }

    @Test("a registration left unsent asks to sign in again once the credentials are readable, until a sign-in goes through")
    func signInAgainGoesAwayAfterASignIn() async throws {
        try await withNoSyncPreferencesPending {
            let backend = BackendFixture(signedIn: false)
            let auth = AuthService(keychainHasCredentials: { false }, notificationCenter: NotificationCenter())
            auth.authTokenManager = backend.manager
            await backend.manager.setNoSessionHandler { await auth.ensureBackendSignedIn() }
            SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)
            let push = RegistrationFixture(manager: backend.manager)
            for _ in 0..<4 { push.answerAnnounce() }
            let keychain = MemoryKeychain.locked()

            try await SecureStore.$sharedForTesting.withValue(keychain) {
                // Behind a locked screen the sign-in finds no credentials, and nothing is sent.
                await push.register()
                let unsent = await push.service.snapshot()
                try #require(unsent.lastAttemptFoundNoSession)
                #expect(await !auth.asksToSignInAgain(syncEnabled: true, after: unsent))

                keychain.unlock()
                #expect(await auth.asksToSignInAgain(syncEnabled: true, after: unsent))

                await auth.ensureBackendSignedIn()
                #expect(await !auth.asksToSignInAgain(syncEnabled: true, after: unsent))

                push.answerAnnounce()
                push.answerRegister()
                await push.service.registerAgain()
                await push.service.awaitPendingRegistration()
            }

            let registered = await push.service.snapshot()
            #expect(registered.lastError == nil)
            #expect(!registered.lastAttemptFoundNoSession)
            #expect(await !auth.asksToSignInAgain(syncEnabled: true, after: registered))
        }
    }

    @Test("while an automatic sign-in is under way the status does not ask to sign in again")
    func signInAgainWaitsForTheRunningSignIn() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture(signedIn: false)
        let auth = AuthService(keychainHasCredentials: { false }, notificationCenter: NotificationCenter())
        auth.authTokenManager = backend.manager
        SettingsAPIStub.enqueue(.init(statusCode: 503, body: Data(), gate: gate), for: backend.loginURL)

        try await SecureStore.$sharedForTesting.withValue(MemoryKeychain.signedIn()) {
            async let signIn: Void = auth.ensureBackendSignedIn()
            try await waitUntil { SettingsAPIStub.requests(for: backend.loginURL).count == 1 }
            #expect(auth.isSigningInToBackend)
            #expect(await !auth.asksToSignInAgain(syncEnabled: true, after: Self.unsentRegistration))

            gate.open()
            await signIn
            #expect(!auth.isSigningInToBackend)
            #expect(await auth.asksToSignInAgain(syncEnabled: true, after: Self.unsentRegistration))
        }
    }

    @Test("with no backend client the status does not ask to sign in again")
    func signInAgainNeedsABackend() async {
        let auth = AuthService(keychainHasCredentials: { false }, notificationCenter: NotificationCenter())

        let asks = await SecureStore.$sharedForTesting.withValue(MemoryKeychain.signedIn()) {
            await auth.asksToSignInAgain(syncEnabled: true, after: Self.unsentRegistration)
        }

        #expect(!asks)
    }

    /// A registration that went unsent for want of a session.
    private static let unsentRegistration = PushRegistrationSnapshot(
        ptsTokenLength: 0, deviceTokenLength: 6, lastError: "register: x",
        lastAttemptFoundNoSession: true, lastRegisteredAt: nil
    )
}

/// An `AuthTokenManager` on `SettingsAPIStub` whose access token has expired, so its next
/// `validAccessToken()` refreshes with refresh token R0.
private struct BackendFixture {
    let manager: AuthTokenManager
    let recorder: Recorder
    let refreshURL: URL
    let loginURL: URL

    init(signedIn: Bool = true) {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        refreshURL = baseURL.appendingPathComponent("auth/refresh")
        loginURL = baseURL.appendingPathComponent("auth/login")
        let recorder = Recorder(
            tokens: signedIn
                ? [
                    AuthTokenManager.accessTokenKey: "A0",
                    AuthTokenManager.refreshTokenKey: "R0",
                    AuthTokenManager.expiresAtKey: "0",
                ]
                : [:],
            refreshURL: refreshURL
        )
        self.recorder = recorder
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        manager = AuthTokenManager(
            baseURLProvider: { baseURL },
            deviceUUID: "test-device",
            session: URLSession(configuration: config),
            tokens: recorder.tokenStore,
            beginBackgroundTask: { recorder.beginBackgroundTask() }
        )
    }

    /// The refresh token each refresh request carried, in order.
    func sentRefreshTokens() throws -> [String] {
        try SettingsAPIStub.requests(for: refreshURL).map { request in
            let body = try #require(SettingsAPIStub.bodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            return try #require(json["refresh_token"])
        }
    }

    /// Each login request's body, in order.
    func sentLoginBodies() throws -> [[String: Any]] {
        try SettingsAPIStub.requests(for: loginURL).map { request in
            let body = try #require(SettingsAPIStub.bodyData(from: request))
            return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
    }

    /// The Moodle token each login request carried, in order.
    func sentMoodleTokens() throws -> [String?] {
        try sentLoginBodies().map { $0["moodle_token"] as? String }
    }

    static func refreshReply(
        access: String, refresh: String, heldBy gate: SettingsAPIStub.ReplyGate? = nil
    ) -> SettingsAPIStub.StubResponse {
        .init(statusCode: 200, body: Data("""
            {"access_token":"\(access)","refresh_token":"\(refresh)","token_type":"Bearer","expires_in":900}
            """.utf8), gate: gate)
    }

    static func loginReply(
        access: String, refresh: String, heldBy gate: SettingsAPIStub.ReplyGate? = nil
    ) -> SettingsAPIStub.StubResponse {
        .init(statusCode: 200, body: Data("""
            {"access_token":"\(access)","refresh_token":"\(refresh)","token_type":"Bearer","expires_in":900,\
            "user":{"id":"user-1","student_id":"B11000000","display_name":null},"device_id":"device-1"}
            """.utf8), gate: gate)
    }

    static var reuseDetected: SettingsAPIStub.StubResponse {
        .init(statusCode: 401, body: Data(#"{"detail":"refresh_reuse_detected"}"#.utf8))
    }
}

/// A registration service whose requests carry `manager`'s session, as `PushCoordinator` wires
/// it, with its debounce and backoff ending at once.
private struct RegistrationFixture {
    let service: PushRegistrationService
    let announceURL: URL
    let registerURL: URL

    init(manager: AuthTokenManager) {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        announceURL = baseURL.appendingPathComponent("devices/anonymous")
        registerURL = baseURL.appendingPathComponent("devices/register")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        service = PushRegistrationService(
            identity: PushIdentity(uuid: "test-device"),
            apiClient: PushAPIClient(
                baseURLProvider: { baseURL },
                session: URLSession(configuration: config),
                authHeaderProvider: { await manager.authorizationHeader() }
            ),
            deviceClass: "iphone",
            debounceSleep: { _ in },
            retrySleep: { _ in }
        )
    }

    func answerAnnounce() {
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data("{}".utf8)), for: announceURL)
    }

    func answerRegister() {
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: Data(#"{"device_id":"server-device","push_token_id":1}"#.utf8)),
            for: registerURL
        )
    }

    /// Registers the standard token and waits for the attempt and the retries it schedules.
    func register() async {
        await service.update(deviceToken: Data([0xAB, 0xCD, 0xEF]))
        await service.awaitPendingRegistration()
    }
}

/// The Keychain and the UIKit background task in one, so it can tell whether a token write
/// happened while a background task ran.
private nonisolated final class Recorder: @unchecked Sendable {
    struct BackgroundTasks {
        var begun = 0
        var ended = 0
        var requestsAtFirstBegin: Int?
    }

    private let lock = NSLock()
    private let refreshURL: URL
    private var values: [String: String]
    private var tasks = BackgroundTasks()
    private var outsideWrites = 0

    init(tokens: [String: String], refreshURL: URL) {
        values = tokens
        self.refreshURL = refreshURL
    }

    var tokenStore: AuthTokenManager.TokenStore {
        AuthTokenManager.TokenStore(
            load: { key in self.lock.withLock { self.values[key] } },
            save: { key, value in
                self.lock.withLock {
                    if self.tasks.begun == self.tasks.ended { self.outsideWrites += 1 }
                    self.values[key] = value
                }
            },
            delete: { key in self.lock.withLock { self.values[key] = nil } }
        )
    }

    func beginBackgroundTask() -> @Sendable () async -> Void {
        let sent = SettingsAPIStub.requests(for: refreshURL).count
        lock.withLock {
            tasks.begun += 1
            if tasks.requestsAtFirstBegin == nil { tasks.requestsAtFirstBegin = sent }
        }
        return { self.lock.withLock { self.tasks.ended += 1 } }
    }

    func stored(_ key: String) -> String? { lock.withLock { values[key] } }
    var backgroundTasks: BackgroundTasks { lock.withLock { tasks } }
    var writesOutsideABackgroundTask: Int { lock.withLock { outsideWrites } }
}

private nonisolated final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private extension MoodleTokenService {
    /// Has no token stored. Its harvest hands out "harvested", or fails with `failure`, and
    /// reaches no school server.
    static func standIn(
        harvests: CallCount,
        failure: MoodleWebserviceError? = nil
    ) -> MoodleTokenService {
        let stored = OSAllocatedUnfairLock<String?>(initialState: nil)
        return MoodleTokenService(
            storedCredentials: { (studentId: "B11000000", password: "password") },
            tokens: TokenStore(
                load: { stored.withLock { $0 } },
                save: { triple in stored.withLock { $0 = triple.wstoken } },
                drop: { stored.withLock { $0 = nil } }
            ),
            harvest: { _, _ in
                harvests.increment()
                if let failure { throw failure }
                return TokenTriple(signature: "", wstoken: "harvested", privatetoken: nil)
            }
        )
    }
}

/// Runs `body` with `syncPreferencesPushPending`, which a registration that goes through reads,
/// cleared, then puts it back. It is a real `Defaults` key, so this takes the shared gate.
private func withNoSyncPreferencesPending<T>(_ body: () async throws -> T) async rethrows -> T {
    try await withExclusiveRealDefaults {
        let saved = Defaults[.syncPreferencesPushPending]
        Defaults[.syncPreferencesPushPending] = false
        defer { Defaults[.syncPreferencesPushPending] = saved }
        return try await body()
    }
}

/// Runs `body` with the stored-password latch, which stops a harvest before it starts, cleared,
/// then puts it back. The latch is a real `Defaults` key, so this takes the shared gate.
private func withPasswordLatchCleared<T>(_ body: () async throws -> T) async rethrows -> T {
    try await withExclusiveRealDefaults {
        let saved = SSOLoginService.storedPasswordRejected
        SSOLoginService.storedPasswordRejected = false
        defer { SSOLoginService.storedPasswordRejected = saved }
        return try await body()
    }
}

/// `SecureStore`'s `.whenUnlockedThisDeviceOnly` valet in memory, holding the NTUST account and
/// Moodle token a backend sign-in sends.
nonisolated final class MemoryKeychain: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    static func signedIn(withMoodleToken: Bool = true) -> MemoryKeychain {
        let keychain = MemoryKeychain()
        keychain.unlock(withMoodleToken: withMoodleToken)
        return keychain
    }

    /// Reads nothing, as behind a locked screen, until `unlock`.
    static func locked() -> MemoryKeychain {
        MemoryKeychain()
    }

    private init() {}

    func unlock(withMoodleToken: Bool = true) {
        lock.withLock {
            items[AppConstants.KeychainKeys.studentId] = Data("B11000000".utf8)
            items[AppConstants.KeychainKeys.password] = Data("password".utf8)
            if withMoodleToken {
                items[AppConstants.KeychainKeys.moodleToken] = Data("moodle-token".utf8)
            }
        }
    }

    func object(forKey key: String) throws -> Data {
        try lock.withLock {
            guard let item = items[key] else { throw KeychainError.itemNotFound }
            return item
        }
    }

    func setObject(_ object: Data, forKey key: String) throws {
        lock.withLock { items[key] = object }
    }

    func removeObject(forKey key: String) throws {
        lock.withLock { items[key] = nil }
    }

    func removeAllObjects() throws {
        lock.withLock { items.removeAll() }
    }
}
