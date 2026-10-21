// `AuthTokenManager` and `AuthService` through `SettingsAPIStub`. The backend rotates the refresh
// token on every refresh, takes the old one again for 24 hours while its successor is unused, and
// any other reuse for theft (https://github.com/tigerduck-app/tigerduck-app/issues/375).
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

    /// Both sends may have reached the backend, the second rotating the token once more, and a
    /// third use is taken for theft (https://github.com/tigerduck-app/tigerduck-app/issues/594).
    @Test("a token whose two sends got no reply goes out no more, and the next refresh signs in again")
    func secondLostReplyGivesUp() async throws {
        let backend = BackendFixture()
        let manager = backend.manager
        let relogins = CallCount()
        await manager.setRefreshFailedHandler {
            relogins.increment()
            return (try? await manager.login(
                studentId: "B11000000", moodleToken: "moodle-token",
                moodlePrivateToken: nil, platform: "ios"
            )) != nil
        }
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A3", refresh: "R3"), for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)

        #expect(await manager.validAccessToken() == nil)

        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R0")
        #expect(await manager.isLoggedIn)
        #expect(relogins.value == 0)
        #expect(await manager.validAccessToken() == "A9")
        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
        #expect(relogins.value == 1)
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R9")
    }

    /// The count lives with the tokens, so the app ending between the second lost reply and the
    /// next sign-in does not send the token a third time
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/604).
    @Test("after a relaunch, a token whose two sends got no reply goes out no more")
    func theUseCountOutlivesARelaunch() async throws {
        let backend = BackendFixture()
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        #expect(await backend.manager.validAccessToken() == nil)

        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A3", refresh: "R3"), for: backend.refreshURL)
        #expect(await backend.relaunched().validAccessToken() == nil)

        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
    }

    /// A send can end with the app before its reply comes back.
    @Test("a refresh counts its send on disk before the request goes out, and a new pair clears it")
    func theCountIsSavedBeforeTheSend() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1", heldBy: gate), for: backend.refreshURL)
        let refresh = Task { await backend.manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenUsesKey) == "1")
        gate.open()
        #expect(await refresh.value == "A1")
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenUsesKey) == nil)
    }

    /// A count the Keychain did not take would not outlive the app, so the token does not go out.
    @Test("a refresh whose count could not be saved sends nothing")
    func anUnsavedCountSendsNothing() async throws {
        let backend = BackendFixture()
        var tokens = backend.recorder.tokenStore
        tokens.confirmedSave = { _, _ in false }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let manager = AuthTokenManager(
            baseURLProvider: { backend.refreshURL.deletingLastPathComponent().deletingLastPathComponent() },
            deviceUUID: "test-device", session: URLSession(configuration: config), tokens: tokens,
            beginBackgroundTask: { {} }
        )
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)

        #expect(await manager.validAccessToken() == nil)

        #expect(SettingsAPIStub.requests(for: backend.refreshURL).isEmpty)
    }

    /// Sent while the spent token stayed on disk, the new token would leave its count on that one.
    @Test("a new token the Keychain refused goes out only once it is stored, and the old one never again")
    func aRefusedNewTokenWaitsUntilStored() async throws {
        let backend = BackendFixture()
        let refused = OSAllocatedUnfairLock(initialState: true)
        let manager = backend.refusingRefreshToken(while: refused)
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1", expiresIn: 0), for: backend.refreshURL)
        #expect(await manager.validAccessToken() == "A1")
        #expect(await manager.validAccessToken() == nil)
        #expect(await backend.relaunched().validAccessToken() == nil)

        refused.withLock { $0 = false }
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A2", refresh: "R2"), for: backend.refreshURL)
        #expect(await manager.validAccessToken() == "A2")

        #expect(try backend.sentRefreshTokens() == ["R0", "R0", "R1"])
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R2")
    }

    @Test("a sign-out that could not delete the token keeps its count for the next launch")
    func aTokenTheSignOutCouldNotDeleteKeepsItsCount() async throws {
        let backend = BackendFixture()
        let manager = backend.refusingRefreshToken(while: OSAllocatedUnfairLock(initialState: true))
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        #expect(await manager.validAccessToken() == nil)

        await manager.logout()
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)
        _ = await backend.relaunched().validAccessToken()

        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
    }

    @Test("the sign-out's last send of a token it could not delete leaves it spent for the next launch")
    func theSignOutsLastSendLeavesTheTokenSpent() async throws {
        let backend = BackendFixture()
        let manager = backend.refusingRefreshToken(while: OSAllocatedUnfairLock(initialState: true))
        SettingsAPIStub.enqueue(.init(statusCode: 503, body: Data()), for: backend.refreshURL)
        #expect(await manager.validAccessToken() == nil)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A9", refresh: "R9"), for: backend.refreshURL)

        #expect(await manager.endSession() == "A9")
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)
        _ = await backend.relaunched().validAccessToken()

        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
    }

    @Test("a refresh the backend turned down takes its send off the count again")
    func aTurnedDownSendIsNotCounted() async throws {
        let backend = BackendFixture()
        SettingsAPIStub.enqueue(.init(statusCode: 403, body: Data(#"{"detail":"x"}"#.utf8)), for: backend.refreshURL)

        #expect(await backend.manager.validAccessToken() == nil)

        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R0")
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenUsesKey) == "0")
    }

    @Test("a sign-out clears the count with the tokens")
    func aSignOutClearsTheCount() async throws {
        let backend = BackendFixture()
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        #expect(await backend.manager.validAccessToken() == nil)
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenUsesKey) == "2")

        await backend.manager.logout()

        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenUsesKey) == nil)
    }

    /// The count belongs to the token the refresh sent, not to the next account's.
    @Test("a refresh a sign-out overtook writes no count for the next account's token")
    func anOvertakenRefreshWritesNoCount() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        let manager = backend.manager
        SettingsAPIStub.enqueue(.init(statusCode: 503, body: Data(), gate: gate), for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)
        let refresh = Task { await manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        await manager.logout()
        _ = try await manager.login(
            studentId: "B11000000", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
        gate.open()
        _ = await refresh.value

        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R9")
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenUsesKey) == nil)
    }

    @Test("a token's two sends span refreshes: after a server error, a lost reply is not sent again")
    func sendsAddUpAcrossRefreshes() async throws {
        let backend = BackendFixture()
        SettingsAPIStub.enqueue(.init(statusCode: 503, body: Data()), for: backend.refreshURL)
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)

        #expect(await backend.manager.validAccessToken() == nil)
        #expect(await backend.manager.validAccessToken() == nil)

        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
    }

    /// The backend's per-IP limit answers before it looks at the token, and a campus network puts
    /// many students behind one IP.
    @Test("a refresh turned away by the rate limit uses none of the token's sends")
    func rateLimitedRefreshesUseNothing() async throws {
        let backend = BackendFixture()
        for _ in 0..<3 {
            SettingsAPIStub.enqueue(.init(statusCode: 429, body: Data(#"{"detail":"x"}"#.utf8)), for: backend.refreshURL)
        }
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)

        for _ in 0..<3 { #expect(await backend.manager.validAccessToken() == nil) }

        #expect(await backend.manager.validAccessToken() == "A1")
        #expect(try backend.sentRefreshTokens() == ["R0", "R0", "R0", "R0"])
    }

    private static var offline: SettingsAPIStub.StubResponse {
        .init(statusCode: 0, body: Data(), failure: .notConnectedToInternet)
    }

    /// Offline, the request never leaves the device, so the backend cannot have used the token.
    @Test("a refresh that never leaves the device uses none of the token's sends")
    func offlineRefreshesUseNothing() async throws {
        let backend = BackendFixture()
        for _ in 0..<4 { SettingsAPIStub.enqueue(Self.offline, for: backend.refreshURL) }
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)

        #expect(await backend.manager.validAccessToken() == nil)
        #expect(await backend.manager.validAccessToken() == nil)

        #expect(await backend.manager.validAccessToken() == "A1")
        #expect(try backend.sentRefreshTokens() == ["R0", "R0", "R0", "R0", "R0"])
    }

    /// Behind a captive portal's sign-in page, as on campus or public Wi-Fi, the TLS handshake
    /// fails before the request carrying the token goes out; so does a request iOS refuses to send.
    @Test("a refresh that fails before its request goes out keeps the token for the next one", arguments: [
        URLError.Code.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
        .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection, .badURL, .unsupportedURL,
    ])
    func refreshFailingBeforeItGoesOutKeepsTheToken(code: URLError.Code) async throws {
        let backend = BackendFixture()
        let failure = SettingsAPIStub.StubResponse(statusCode: 0, body: Data(), failure: code)
        SettingsAPIStub.enqueue(failure, for: backend.refreshURL)
        SettingsAPIStub.enqueue(failure, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)

        #expect(await backend.manager.validAccessToken() == nil)

        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R0")
        #expect(await backend.manager.validAccessToken() == "A1")
        #expect(try backend.sentRefreshTokens() == ["R0", "R0", "R0"])
    }

    @Test("a refresh that may have reached the backend still counts", arguments: [
        URLError.Code.timedOut, .networkConnectionLost, .cancelled,
    ])
    func refreshThatMayHaveGoneOutCounts(code: URLError.Code) async throws {
        let backend = BackendFixture()
        let failure = SettingsAPIStub.StubResponse(statusCode: 0, body: Data(), failure: code)
        SettingsAPIStub.enqueue(failure, for: backend.refreshURL)
        SettingsAPIStub.enqueue(failure, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)

        #expect(await backend.manager.validAccessToken() == nil)
        #expect(await backend.manager.validAccessToken() == nil)

        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
    }

    @Test("a sign-out after a refresh that never left the device still gets a token for its unregister")
    func signOutAfterAnOfflineRefreshSendsTheToken() async throws {
        let backend = BackendFixture()
        SettingsAPIStub.enqueue(Self.offline, for: backend.refreshURL)
        SettingsAPIStub.enqueue(Self.offline, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)
        #expect(await backend.manager.validAccessToken() == nil)

        #expect(await backend.manager.endSession() == "A1")
    }

    @Test("a new pair gets two sends of its own")
    func aNewPairStartsTheCountOver() async throws {
        let backend = BackendFixture()
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        // Expired at once, so the next call refreshes it.
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1", expiresIn: 0), for: backend.refreshURL)
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)

        #expect(await backend.manager.validAccessToken() == "A1")
        #expect(await backend.manager.validAccessToken() == nil)

        #expect(try backend.sentRefreshTokens() == ["R0", "R0", "R1", "R1"])
    }

    @Test("a refresh request with no reply gives up after 20 seconds")
    func refreshRequestTimesOut() async throws {
        let backend = BackendFixture(refreshTimeout: AuthTokenManager.refreshTimeout)
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

    /// Sign-out unregisters the device as the departing account
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/411), while the session has already
    /// ended for everything else, the keychain included.
    @Test("a sign-out ends the session at once, and only its own calls still carry the account's token")
    func signOutEndsTheSessionButItsCallsGoOut() async throws {
        let backend = BackendFixture()
        let registration = RegistrationFixture(manager: backend.manager)
        // A0 has expired, so the token kept for the sign-out's calls is refreshed first.
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)
        SettingsAPIStub.enqueue(.init(statusCode: 204, body: Data()), for: registration.unregisterURL)

        let token = await backend.manager.endSession()

        #expect(token == "A1")
        #expect(await !backend.manager.isLoggedIn)
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == nil)
        await registration.service.unregister()
        #expect(SettingsAPIStub.requests(for: registration.unregisterURL).isEmpty)
        await AuthTokenManager.$departing.withValue(.init(accessToken: token)) {
            await registration.service.unregister()
        }
        let unregister = try #require(SettingsAPIStub.requests(for: registration.unregisterURL).first)
        #expect(unregister.value(forHTTPHeaderField: "Authorization") == "Bearer A1")
    }

    /// The refresh is out only when the token would not outlast the unregister. Another call meanwhile
    /// would go as the departing account, and the TigerSync-off PATCH deletes its synced data.
    @Test("while a sign-out refreshes the token for its unregister, no one else has a session")
    func signOutRefreshLeavesNoSession() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        let manager = backend.manager
        SettingsAPIStub.enqueue(
            BackendFixture.refreshReply(access: "A1", refresh: "R1", heldBy: gate), for: backend.refreshURL
        )
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: backend.loginURL)

        let ending = Task { await manager.endSession() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }
        #expect(await !manager.isLoggedIn)
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == nil)
        _ = try await manager.login(
            studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
        gate.open()

        #expect(await ending.value == "A1")
        #expect(await manager.validAccessToken() == "B1")
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "BR1")
    }

    @Test("a sign-out's last send counts nothing against a token a sign-in stored meanwhile")
    func theSignOutsLastSendSparesTheNextToken() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        let manager = backend.manager
        SettingsAPIStub.enqueue(.init(statusCode: 503, body: Data(), gate: gate), for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: backend.loginURL)
        let refresh = Task { await manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        let ending = Task { await manager.endSession() }
        try await waitUntil { backend.recorder.stored(AuthTokenManager.refreshTokenKey) == nil }
        _ = try await manager.login(
            studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
        gate.open()
        _ = await refresh.value

        #expect(await ending.value == "A1")
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "BR1")
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenUsesKey) == nil)
    }

    @Test("a sign-out's last send still counts against its token when a sign-in meanwhile stored none")
    func theSignOutsLastSendCountsWhileTheNextTokenIsUnstored() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        let manager = backend.refusingRefreshToken(while: OSAllocatedUnfairLock(initialState: true))
        SettingsAPIStub.enqueue(.init(statusCode: 503, body: Data(), gate: gate), for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: backend.loginURL)
        let refresh = Task { await manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        let ending = Task { await manager.endSession() }
        try await waitUntil { backend.recorder.stored(AuthTokenManager.accessTokenKey) == nil }
        _ = try await manager.login(
            studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
        gate.open()
        _ = await refresh.value

        #expect(await ending.value == "A1")
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R0")
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenUsesKey) == "2")
    }

    @Test("a sign-in while a sign-out's calls are out keeps its session, and they keep the departing token")
    func signInDuringTheSignOutCalls() async throws {
        let backend = BackendFixture()
        let manager = backend.manager
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: backend.loginURL)

        let token = await manager.endSession()
        _ = try await manager.login(
            studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
        let departing = await AuthTokenManager.$departing.withValue(.init(accessToken: token)) {
            await manager.validAccessToken()
        }

        #expect(departing == "A1")
        #expect(await manager.validAccessToken() == "B1")
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "BR1")
    }

    @Test("a sign-out whose token outlasts its unregister refreshes nothing")
    func signOutKeepsATokenThatLasts() async {
        let backend = BackendFixture(accessTokenExpiry: Date.now.addingTimeInterval(600))

        #expect(await backend.manager.endSession() == "A0")
        #expect(SettingsAPIStub.requests(for: backend.refreshURL).isEmpty)
    }

    @Test("a sign-out whose refresh is turned down sends no unregister")
    func signOutWithoutATokenSendsNothing() async {
        let backend = BackendFixture()
        let registration = RegistrationFixture(manager: backend.manager)
        SettingsAPIStub.enqueue(BackendFixture.reuseDetected, for: backend.refreshURL)

        let token = await backend.manager.endSession()
        await AuthTokenManager.$departing.withValue(.init(accessToken: token)) {
            await registration.service.unregister()
        }

        #expect(token == nil)
        #expect(SettingsAPIStub.requests(for: registration.unregisterURL).isEmpty)
    }

    @Test("a login still out when a sign-out starts stores nothing")
    func signOutDropsALoginInFlight() async throws {
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

        #expect(await manager.endSession() == nil)
        gate.open()

        await #expect(throws: CancellationError.self) { try await login.value }
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

    // MARK: - Refreshes a sign-out meets (https://github.com/tigerduck-app/tigerduck-app/issues/468)

    /// The refresh already out may be the retry after a lost reply, the token's second use; one
    /// more from the sign-out is taken for theft and revokes the device's sessions, the unregister
    /// with them.
    @Test("a sign-out while a refresh is out takes that refresh's token instead of sending another")
    func signOutDuringARefreshTakesItsToken() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        let manager = backend.manager
        SettingsAPIStub.enqueue(
            BackendFixture.refreshReply(access: "A1", refresh: "R1", heldBy: gate), for: backend.refreshURL
        )
        let refresh = Task { await manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        let ending = Task { await manager.endSession() }
        while await manager.isLoggedIn { try await Task.sleep(for: .milliseconds(5)) }
        gate.open()

        #expect(await ending.value == "A1")
        #expect(await refresh.value == nil)
        #expect(try backend.sentRefreshTokens() == ["R0"])
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == nil)
    }

    /// Sent once, the token may go once more: the backend rotates it again while nothing has used
    /// the pair a lost reply carried, and a server error may not have rotated it at all.
    @Test("a sign-out whose refresh got no reply or a server error sends the token once more", arguments: [
        SettingsAPIStub.StubResponse.noReply,
        SettingsAPIStub.StubResponse(statusCode: 503, body: Data()),
    ])
    func signOutResendsARefreshThatGotNoToken(firstReply: SettingsAPIStub.StubResponse) async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        let manager = backend.manager
        var held = firstReply
        held.gate = gate
        SettingsAPIStub.enqueue(held, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)
        let refresh = Task { await manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        let ending = Task { await manager.endSession() }
        while await manager.isLoggedIn { try await Task.sleep(for: .milliseconds(5)) }
        gate.open()

        #expect(await ending.value == "A1")
        #expect(await refresh.value == nil)
        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == nil)
    }

    @Test("a sign-out sends no third use of a refresh token its refresh already sent twice")
    func signOutSendsNoThirdUse() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        let manager = backend.manager
        var lostAgain = SettingsAPIStub.StubResponse.noReply
        lostAgain.gate = gate
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(lostAgain, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)
        let refresh = Task { await manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 2 }

        let ending = Task { await manager.endSession() }
        while await manager.isLoggedIn { try await Task.sleep(for: .milliseconds(5)) }
        gate.open()

        #expect(await ending.value == nil)
        #expect(await refresh.value == nil)
        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
    }

    /// Turned down, the token is dead, and one more use of it is taken for theft, which revokes
    /// every session of the device, a sign-in's after this one included.
    @Test("a sign-out sends nothing more for a refresh the backend turned down")
    func signOutSendsNothingAfterARefusal() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        let manager = backend.manager
        var turnedDown = BackendFixture.reuseDetected
        turnedDown.gate = gate
        SettingsAPIStub.enqueue(turnedDown, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)
        let refresh = Task { await manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        let ending = Task { await manager.endSession() }
        while await manager.isLoggedIn { try await Task.sleep(for: .milliseconds(5)) }
        gate.open()

        #expect(await ending.value == nil)
        #expect(await refresh.value == nil)
        #expect(try backend.sentRefreshTokens() == ["R0"])
        #expect(!backend.relaunched().hasDepartingSession)
    }

    @Test("a sign-out sends no third use of a token an earlier refresh sent twice")
    func signOutAfterARefreshThatSentTwiceSendsNothing() async throws {
        let backend = BackendFixture()
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)
        #expect(await backend.manager.validAccessToken() == nil)

        #expect(await backend.manager.endSession() == nil)

        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
        #expect(!backend.relaunched().hasDepartingSession)
    }

    /// The 401 came before the sign-out, so no reply was overtaken, and the sign-out sent the
    /// refused token once more.
    @Test("a sign-out during the relogin after a 401 sends the refused token no more")
    func signOutDuringTheReloginSendsTheRefusedTokenNoMore() async throws {
        let backend = BackendFixture()
        let manager = backend.manager
        let ending = OSAllocatedUnfairLock<Task<String?, Never>?>(initialState: nil)
        await manager.setRefreshFailedHandler {
            // The account signs out while the relogin runs, which then fails.
            ending.withLock { $0 = Task { await manager.endSession() } }
            while await manager.isLoggedIn { try? await Task.sleep(for: .milliseconds(5)) }
            return false
        }
        SettingsAPIStub.enqueue(BackendFixture.reuseDetected, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)

        #expect(await manager.validAccessToken() == nil)

        let signOut = try #require(ending.withLock { $0 })
        #expect(await signOut.value == nil)
        #expect(try backend.sentRefreshTokens() == ["R0"])
    }

    @Test("a refresh turned down after a sign-out signs nothing in again and leaves the next session alone")
    func refreshTurnedDownAfterASignOut() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        let manager = backend.manager
        let relogins = CallCount()
        await manager.setRefreshFailedHandler {
            relogins.increment()
            return false
        }
        var turnedDown = BackendFixture.reuseDetected
        turnedDown.gate = gate
        SettingsAPIStub.enqueue(turnedDown, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: backend.loginURL)
        let refresh = Task { await manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        await manager.logout()
        _ = try await manager.login(
            studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
        gate.open()

        #expect(await refresh.value == nil)
        #expect(relogins.value == 0)
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "BR1")
        #expect(await manager.isLoggedIn)
    }

    @Test("a sign-out during the relogin after a 401 leaves the next session alone")
    func signOutDuringTheReloginAfterA401() async throws {
        let backend = BackendFixture()
        let manager = backend.manager
        SettingsAPIStub.enqueue(BackendFixture.reuseDetected, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: backend.loginURL)
        await manager.setRefreshFailedHandler {
            // The account signs out and the next one signs in while the relogin runs, which fails.
            await manager.logout()
            _ = try? await manager.login(
                studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
            )
            return false
        }

        #expect(await manager.validAccessToken() == nil)

        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "BR1")
        #expect(await manager.isLoggedIn)
    }

    /// The request that asked for the departing account's token gets none, rather than the token
    /// of the account that signed in after it.
    @Test("a relogin that a sign-out outlived hands out no token")
    func reloginASignOutOutlivedHandsOutNoToken() async throws {
        let backend = BackendFixture()
        let manager = backend.manager
        SettingsAPIStub.enqueue(BackendFixture.reuseDetected, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: backend.loginURL)
        await manager.setRefreshFailedHandler {
            await manager.logout()
            _ = try? await manager.login(
                studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
            )
            return true
        }

        #expect(await manager.validAccessToken() == nil)

        #expect(await manager.validAccessToken() == "B1")
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

/// A sign-out's unregister that did not land: the session it ended stays for a later launch to send
/// the unregister as that account (https://github.com/tigerduck-app/tigerduck-app/issues/460).
@Suite("The session a sign-out keeps for its unregister")
struct DepartingSessionTests {
    /// The kept session's refresh token, its sends and the backend it belongs to, or nil with none kept.
    private static func kept(_ backend: BackendFixture) throws -> (token: String, uses: Int, baseURL: String?)? {
        guard let json = backend.recorder.stored(AuthTokenManager.departingSessionKey) else { return nil }
        let session = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return (
            try #require(session["refreshToken"] as? String), try #require(session["uses"] as? Int),
            session["baseURL"] as? String
        )
    }

    /// Signed in with an access token that outlasts the sign-out's calls, so the sign-out sends nothing.
    private static func signedOut() async -> BackendFixture {
        let backend = BackendFixture(accessTokenExpiry: Date.now.addingTimeInterval(600))
        _ = await backend.manager.endSession()
        return backend
    }

    @Test("a sign-out keeps the session it ends, and a later launch refreshes it once for the unregister")
    func aLaterLaunchRefreshesTheKeptSession() async throws {
        let backend = await Self.signedOut()
        #expect(try Self.kept(backend)?.token == "R0")
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)

        let relaunched = backend.relaunched()
        #expect(relaunched.hasDepartingSession)
        #expect(await relaunched.departingAccessToken() == "A1")

        #expect(try backend.sentRefreshTokens() == ["R0"])
        #expect(try Self.kept(backend)?.token == "R1")
        #expect(try Self.kept(backend)?.uses == 0)
        #expect(try Self.kept(backend)?.baseURL == backend.baseURL.absoluteString)
        #expect(await !relaunched.isLoggedIn)
    }

    @Test("a sign-out counts its own refresh in the session it keeps before the request goes out, and keeps the next token")
    func theSignOutsRefreshIsCountedThenItsTokenKept() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        SettingsAPIStub.enqueue(
            BackendFixture.refreshReply(access: "A1", refresh: "R1", heldBy: gate), for: backend.refreshURL
        )
        let ending = Task { await backend.manager.endSession() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == nil)
        #expect(try Self.kept(backend)?.token == "R0")
        #expect(try Self.kept(backend)?.uses == 1)
        #expect(try Self.kept(backend)?.baseURL == backend.baseURL.absoluteString)
        gate.open()

        #expect(await ending.value == "A1")
        #expect(try Self.kept(backend)?.token == "R1")
        #expect(try Self.kept(backend)?.uses == 0)
        #expect(try Self.kept(backend)?.baseURL == backend.baseURL.absoluteString)
    }

    @Test("a refresh a sign-out overtook leaves the token it brings for the unregister")
    func anOvertakenRefreshLeavesItsToken() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        let manager = backend.manager
        SettingsAPIStub.enqueue(
            BackendFixture.refreshReply(access: "A1", refresh: "R1", heldBy: gate), for: backend.refreshURL
        )
        let refresh = Task { await manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        let ending = Task { await manager.endSession() }
        while await manager.isLoggedIn { try await Task.sleep(for: .milliseconds(5)) }
        gate.open()

        #expect(await ending.value == "A1")
        #expect(await refresh.value == nil)
        #expect(try Self.kept(backend)?.token == "R1")
        #expect(try Self.kept(backend)?.uses == 0)
        #expect(try Self.kept(backend)?.baseURL == backend.baseURL.absoluteString)
    }

    /// The endpoint can change between the sign-out and that launch, and the other server never
    /// issued the session.
    @Test("a kept session is refreshed and unregistered on the backend it was kept against, after the endpoint changed")
    func theRetryGoesToTheBackendTheSessionWasKeptAgainst() async throws {
        let backend = await Self.signedOut()
        let current = SettingsAPIStub.uniqueBaseURL()
        let relaunched = backend.relaunched(at: current)
        let registration = RegistrationFixture(manager: relaunched, baseURL: current)
        let unregisterURL = backend.baseURL.appendingPathComponent("devices/test-device")
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)
        SettingsAPIStub.enqueue(.init(statusCode: 204, body: Data()), for: unregisterURL)

        await relaunched.retryDepartingUnregister { await registration.service.unregisterDevice(at: $0) }

        #expect(try backend.sentRefreshTokens() == ["R0"])
        let unregister = try #require(SettingsAPIStub.requests(for: unregisterURL).first)
        #expect(unregister.value(forHTTPHeaderField: "Authorization") == "Bearer A1")
        #expect(SettingsAPIStub.requests(under: current).isEmpty)
        #expect(try Self.kept(backend) == nil)
    }

    @Test("a kept session the backend turns down is forgotten")
    func aTurnedDownSessionIsForgotten() async throws {
        let backend = await Self.signedOut()
        SettingsAPIStub.enqueue(BackendFixture.reuseDetected, for: backend.refreshURL)

        #expect(await backend.relaunched().departingAccessToken() == nil)

        #expect(try Self.kept(backend) == nil)
        #expect(!backend.relaunched().hasDepartingSession)
    }

    /// The backend takes a third use for theft, which revokes the device's sessions but leaves its
    /// push tokens, so the unregister could never go after it.
    @Test("a kept session sent twice with no reply goes out no more, and is forgotten")
    func aKeptSessionGoesOutNoThirdTime() async throws {
        let backend = await Self.signedOut()
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)

        #expect(await backend.relaunched().departingAccessToken() == nil)
        #expect(try Self.kept(backend)?.uses == 1)
        #expect(try Self.kept(backend)?.baseURL == backend.baseURL.absoluteString)
        #expect(await backend.relaunched().departingAccessToken() == nil)
        #expect(await backend.relaunched().departingAccessToken() == nil)

        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
        #expect(try Self.kept(backend) == nil)
    }

    @Test("a refresh that never left the device uses none of the kept session's sends")
    func anUnsentRefreshCountsNothing() async throws {
        let backend = await Self.signedOut()
        SettingsAPIStub.enqueue(
            .init(statusCode: 0, body: Data(), failure: .notConnectedToInternet), for: backend.refreshURL
        )

        #expect(await backend.relaunched().departingAccessToken() == nil)

        #expect(try Self.kept(backend)?.uses == 0)
    }

    @Test("the unregister goes as the departing account and forgets the kept session once the server has it")
    func theUnregisterForgetsTheKeptSessionOnceItLands() async throws {
        let backend = BackendFixture(accessTokenExpiry: Date.now.addingTimeInterval(600))
        let manager = backend.manager
        let token = await manager.endSession()

        await manager.unregisterDeparting(accessToken: token) { await manager.validAccessToken() == nil }
        #expect(try Self.kept(backend) != nil)

        await manager.unregisterDeparting(accessToken: token) { await manager.validAccessToken() == "A0" }
        #expect(try Self.kept(backend) == nil)
    }

    @Test("a sign-in forgets the kept session: the backend has the device for that account now")
    func aSignInForgetsTheKeptSession() async throws {
        let backend = await Self.signedOut()
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: backend.loginURL)

        _ = try await backend.manager.login(
            studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )

        #expect(try Self.kept(backend) == nil)
    }

    @Test("a refresh of the kept session that a sign-in overtook hands out no token and keeps nothing")
    func aSignInDuringTheRetryGetsNoUnregister() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = await Self.signedOut()
        let manager = backend.relaunched()
        SettingsAPIStub.enqueue(
            BackendFixture.refreshReply(access: "A1", refresh: "R1", heldBy: gate), for: backend.refreshURL
        )
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: backend.loginURL)
        let retry = Task { await manager.departingAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        _ = try await manager.login(
            studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
        gate.open()

        #expect(await retry.value == nil)
        #expect(try Self.kept(backend) == nil)
        #expect(await manager.validAccessToken() == "B1")
    }

    @Test("the device's unregister lands when answered, or when the account has the device no more",
          arguments: zip([204, 404, 401, 500], [true, true, false, false]))
    func theUnregisterLandsOnlyWhenTheServerHasIt(status: Int, lands: Bool) async {
        let backend = BackendFixture()
        let registration = RegistrationFixture(manager: backend.manager)
        SettingsAPIStub.enqueue(.init(statusCode: status, body: Data()), for: registration.unregisterURL)

        let landed = await AuthTokenManager.$departing.withValue(.init(accessToken: "A1")) {
            await registration.service.unregisterDevice()
        }

        #expect(landed == lands)
    }
}

@Suite("Backend sign-in")
@MainActor
struct BackendSignInTests {
    @Test("the sign-ins after the school's store nothing once the account has signed out")
    func servicesAfterASignOutStoreNothing() async throws {
        let backend = BackendFixture(signedIn: false)
        let harvests = CallCount()
        let auth = AuthService(
            keychainHasCredentials: { false },
            notificationCenter: NotificationCenter(),
            moodleTokens: .standIn(harvests: harvests)
        )
        auth.authTokenManager = backend.manager
        let keychain = MemoryKeychain.signedIn()
        // A live library token skips the library sign-in, which would reach the library's server.
        let expiry = Int64(Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1000)
        try keychain.setObject(Data("library-token".utf8), forKey: AppConstants.KeychainKeys.libraryToken)
        try keychain.setObject(Data(String(expiry).utf8), forKey: AppConstants.KeychainKeys.libraryTokenExpiry)

        await SecureStore.$sharedForTesting.withValue(keychain) {
            await auth.signInToServices(
                studentId: "B11000000", password: "password", generation: auth.loginGeneration &- 1
            )
        }

        #expect(harvests.value == 0)
        #expect(SettingsAPIStub.requests(for: backend.loginURL).isEmpty)
    }

    /// Once the school has signed the account in and its credentials are stored, a cancel from the
    /// sign-in sheet lets the rest finish, so Moodle and the backend are not left half signed in
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/589).
    @Test("a sign-in cancelled after the school step still signs in to the backend")
    func signInCancelledAfterTheSchoolStepFinishes() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.ntustCredentialsPresent]
            defer { Defaults[.ntustCredentialsPresent] = saved }
            let backend = BackendFixture(signedIn: false)
            SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)
            let sheet = SheetSignIn()
            let stored = OSAllocatedUnfairLock<String?>(initialState: nil)
            let auth = AuthService(
                keychainHasCredentials: { false },
                notificationCenter: NotificationCenter(),
                moodleTokens: MoodleTokenService(
                    storedCredentials: { nil },
                    tokens: .init(
                        load: { stored.withLock { $0 } },
                        save: { triple in stored.withLock { $0 = triple.wstoken } },
                        drop: { stored.withLock { $0 = nil } }
                    ),
                    harvest: { _, _ in
                        // The user cancels the sheet while the Moodle token is fetched.
                        await MainActor.run { sheet.task?.cancel() }
                        return .init(signature: "", wstoken: "harvested", privatetoken: nil)
                    }
                ),
                schoolSignIn: { _, _ in true },
                endSchoolSession: { _ in }
            )
            auth.authTokenManager = backend.manager
            let keychain = MemoryKeychain.locked()
            // A live library token skips the library sign-in, which would reach the library's server.
            let expiry = Int64(Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1000)
            try keychain.setObject(Data("library-token".utf8), forKey: AppConstants.KeychainKeys.libraryToken)
            try keychain.setObject(Data(String(expiry).utf8), forKey: AppConstants.KeychainKeys.libraryTokenExpiry)

            let signedIn = await SecureStore.$sharedForTesting.withValue(keychain) {
                sheet.task = Task { await auth.login(studentId: "B11000000", password: "password") }
                return await sheet.task?.value
            }

            #expect(signedIn == true)
            #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R9")
        }
    }

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
        try await withNoPasswordRefusals {
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
        try await withNoPasswordRefusals {
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
struct BackendFixture {
    let manager: AuthTokenManager
    let recorder: Recorder
    let baseURL: URL
    let refreshURL: URL
    let loginURL: URL
    let refreshTimeout: TimeInterval

    /// `accessTokenExpiry` is when A0 runs out; the default has it expired. A request the stub
    /// holds outlasts the app's 20 seconds on a busy CI run, so the tests give it far longer.
    init(
        signedIn: Bool = true,
        accessTokenExpiry: Date = Date(timeIntervalSince1970: 0),
        refreshTimeout: TimeInterval = 600
    ) {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        self.baseURL = baseURL
        refreshURL = baseURL.appendingPathComponent("auth/refresh")
        loginURL = baseURL.appendingPathComponent("auth/login")
        let recorder = Recorder(
            tokens: signedIn
                ? [
                    AuthTokenManager.accessTokenKey: "A0",
                    AuthTokenManager.refreshTokenKey: "R0",
                    AuthTokenManager.expiresAtKey: String(accessTokenExpiry.timeIntervalSince1970),
                ]
                : [:],
            refreshURL: refreshURL
        )
        self.recorder = recorder
        self.refreshTimeout = refreshTimeout
        manager = Self.manager(baseURL: baseURL, recorder: recorder, refreshTimeout: refreshTimeout)
    }

    /// A manager on the same Keychain, as after the app ends and starts again, on `baseURL` when
    /// given, as after the endpoint changed.
    func relaunched(at baseURL: URL? = nil) -> AuthTokenManager {
        Self.manager(
            baseURL: baseURL ?? refreshURL.deletingLastPathComponent().deletingLastPathComponent(),
            recorder: recorder, refreshTimeout: refreshTimeout
        )
    }

    /// A manager on the same Keychain, which refuses every write of the refresh token while
    /// `refused` holds and reports it where the store can.
    func refusingRefreshToken(while refused: OSAllocatedUnfairLock<Bool>) -> AuthTokenManager {
        let keychain = recorder.tokenStore
        let refuses = { @Sendable (key: String) in key == AuthTokenManager.refreshTokenKey && refused.withLock { $0 } }
        let tokens = AuthTokenManager.TokenStore(
            load: keychain.load,
            save: { key, value in if !refuses(key) { keychain.save(key, value) } },
            delete: { key in if !refuses(key) { keychain.delete(key) } },
            confirmedSave: { key, value in
                guard !refuses(key) else { return false }
                keychain.save(key, value)
                return true
            },
            confirmedDelete: { key in
                guard !refuses(key) else { return false }
                keychain.delete(key)
                return true
            }
        )
        return Self.manager(
            baseURL: refreshURL.deletingLastPathComponent().deletingLastPathComponent(), recorder: recorder,
            tokens: tokens, refreshTimeout: refreshTimeout
        )
    }

    private static func manager(
        baseURL: URL, recorder: Recorder, tokens: AuthTokenManager.TokenStore? = nil, refreshTimeout: TimeInterval
    ) -> AuthTokenManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return AuthTokenManager(
            baseURLProvider: { baseURL },
            deviceUUID: "test-device",
            session: URLSession(configuration: config),
            tokens: tokens ?? recorder.tokenStore,
            refreshTimeout: refreshTimeout,
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
        access: String, refresh: String, expiresIn: Int = 900, heldBy gate: SettingsAPIStub.ReplyGate? = nil
    ) -> SettingsAPIStub.StubResponse {
        .init(statusCode: 200, body: Data("""
            {"access_token":"\(access)","refresh_token":"\(refresh)","token_type":"Bearer","expires_in":\(expiresIn)}
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
    let unregisterURL: URL

    /// On `baseURL`, the endpoint its requests go to unless told otherwise.
    init(manager: AuthTokenManager, baseURL: URL = SettingsAPIStub.uniqueBaseURL()) {
        announceURL = baseURL.appendingPathComponent("devices/anonymous")
        registerURL = baseURL.appendingPathComponent("devices/register")
        unregisterURL = baseURL.appendingPathComponent("devices/test-device")
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
nonisolated final class Recorder: @unchecked Sendable {
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

/// The sign-in a sign-in sheet started, which a test cancels as the sheet's Cancel does.
@MainActor
private final class SheetSignIn {
    var task: Task<Bool, Never>?
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

/// Runs `body` with no refusals of the stored password, which can hold a harvest back, then puts
/// them back. They are real `Defaults` keys, so this takes the shared gate.
private func withNoPasswordRefusals<T>(_ body: () async throws -> T) async rethrows -> T {
    try await withExclusiveRealDefaults {
        let saved = SSOLoginService.storedPasswordRefusals
        SSOLoginService.forgetStoredPasswordRefusals()
        defer { SSOLoginService.storedPasswordRefusals = saved }
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
