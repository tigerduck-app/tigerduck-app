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

    @Test("a refresh whose reply is lost sends the token again to the backend it went to, though the endpoint changed")
    func aResendKeepsItsBackend() async throws {
        let backend = BackendFixture()
        let other = SettingsAPIStub.uniqueBaseURL()
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let manager = backend.relaunched(following: {
            asked.withLock { count in
                count += 1
                return count == 1 ? backend.baseURL : other
            }
        })
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A2", refresh: "R2"), for: backend.refreshURL)

        #expect(await manager.validAccessToken() == "A2")

        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
        #expect(SettingsAPIStub.requests(under: other).isEmpty)
    }

    @Test("a refresh a sign-out overtakes before it sends goes nowhere, though the endpoint changed meanwhile")
    func aRefreshASignOutOvertakesSendsNothing() async throws {
        let backend = BackendFixture()
        let other = SettingsAPIStub.uniqueBaseURL()
        let endpoint = OSAllocatedUnfairLock(initialState: backend.baseURL)
        let entered = OSAllocatedUnfairLock(initialState: false)
        let released = OSAllocatedUnfairLock(initialState: false)
        let manager = backend.relaunched(following: { endpoint.withLock { $0 } }, beginBackgroundTask: {
            entered.withLock { $0 = true }
            while !released.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
            return {}
        })
        let refresh = Task { await manager.validAccessToken() }
        try await waitUntil { entered.withLock { $0 } }

        _ = manager.beginSignOut()
        endpoint.withLock { $0 = other }
        released.withLock { $0 = true }

        #expect(await refresh.value == nil)
        #expect(SettingsAPIStub.requests(under: other).isEmpty)
        #expect(SettingsAPIStub.requests(for: backend.refreshURL).isEmpty)
    }

    @Test("a sign-out's hold on the tokens lasts until every sign-out started meanwhile has ended its session")
    func overlappingSignOutsHoldTheTokensUntilTheLast() async throws {
        let backend = BackendFixture(accessTokenExpiry: Date.now.addingTimeInterval(600))
        let manager = backend.manager
        _ = manager.beginSignOut()
        _ = manager.beginSignOut()
        _ = await manager.endSession()
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: backend.loginURL)
        _ = try await manager.login(
            studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )

        #expect(await manager.validAccessToken() == nil)
        _ = await manager.endSession()
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "C1", refresh: "CR1"), for: backend.loginURL)
        _ = try await manager.login(
            studentId: "B11000002", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
        #expect(await manager.validAccessToken() == "C1")
    }

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

    /// A sign-in sends no refresh token, so a Keychain that refuses every count does not leave the
    /// device without a session once the access token runs out.
    @Test("a refresh whose count could not be saved sends nothing and signs in again")
    func anUnsavedCountSignsInAgain() async throws {
        let backend = BackendFixture()
        let manager = backend.refusingWrites { key, _ in key == AuthTokenManager.refreshTokenUsesKey }
        let relogins = CallCount()
        await manager.setRefreshFailedHandler {
            relogins.increment()
            return (try? await manager.login(
                studentId: "B11000000", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
            )) != nil
        }
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)

        #expect(await manager.validAccessToken() == "A9")

        #expect(SettingsAPIStub.requests(for: backend.refreshURL).isEmpty)
        #expect(relogins.value == 1)
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R9")
    }

    @Test("a refresh whose count could not be saved keeps the token when the sign-in fails too")
    func anUnsavedCountKeepsTheTokenWhenTheSignInFails() async throws {
        let backend = BackendFixture()
        let manager = backend.refusingWrites { key, _ in key == AuthTokenManager.refreshTokenUsesKey }
        let relogins = CallCount()
        await manager.setRefreshFailedHandler {
            relogins.increment()
            return false
        }
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)

        #expect(await manager.validAccessToken() == nil)

        #expect(SettingsAPIStub.requests(for: backend.refreshURL).isEmpty)
        #expect(relogins.value == 1)
        #expect(await manager.isLoggedIn)
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R0")
    }

    @Test("a resend after a lost reply whose count could not be saved signs in again")
    func anUnsavedResendCountSignsInAgain() async throws {
        let backend = BackendFixture()
        let manager = backend.refusingWrites { key, value in key == AuthTokenManager.refreshTokenUsesKey && value == "2" }
        let relogins = CallCount()
        await manager.setRefreshFailedHandler {
            relogins.increment()
            return (try? await manager.login(
                studentId: "B11000000", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
            )) != nil
        }
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A2", refresh: "R2"), for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)

        #expect(await manager.validAccessToken() == "A9")

        #expect(try backend.sentRefreshTokens() == ["R0"])
        #expect(relogins.value == 1)
    }

    @Test("a refresh whose token a sign-in replaced while its reply was lost sends it no more and signs nothing in")
    func aTokenASignInReplacedIsNotResent() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        let manager = backend.manager
        let relogins = CallCount()
        await manager.setRefreshFailedHandler {
            relogins.increment()
            return false
        }
        var lost = SettingsAPIStub.StubResponse.noReply
        lost.gate = gate
        SettingsAPIStub.enqueue(lost, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A2", refresh: "R2"), for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)
        let refresh = Task { await manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        _ = try await manager.login(
            studentId: "B11000000", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
        gate.open()

        #expect(await refresh.value == nil)
        #expect(try backend.sentRefreshTokens() == ["R0"])
        #expect(relogins.value == 0)
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R9")
    }

    @Test("a refresh whose pair comes back after a sign-in stored its own leaves the sign-in's")
    func aRefreshPairASignInOvertookIsNotStored() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        let manager = backend.manager
        SettingsAPIStub.enqueue(
            BackendFixture.refreshReply(access: "A1", refresh: "R1", heldBy: gate), for: backend.refreshURL
        )
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)
        let refresh = Task { await manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        _ = try await manager.login(
            studentId: "B11000000", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
        gate.open()

        #expect(await refresh.value == nil)
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R9")
        #expect(await manager.validAccessToken() == "A9")
    }

    @Test("a refresh refused after a sign-in stored its pair keeps that pair and asks for no relogin")
    func aRefusalASignInOvertookKeepsItsPair() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        let manager = backend.manager
        let relogins = CallCount()
        await manager.setRefreshFailedHandler {
            relogins.increment()
            return false
        }
        var revoked = BackendFixture.sessionRevoked
        revoked.gate = gate
        SettingsAPIStub.enqueue(revoked, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)
        let refresh = Task { await manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        _ = try await manager.login(
            studentId: "B11000000", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
        gate.open()

        #expect(await refresh.value == nil)
        #expect(relogins.value == 0)
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R9")
        #expect(await manager.validAccessToken() == "A9")
    }

    @Test("a sign-in during a relogin that fails after a 401 keeps its pair")
    func aSignInDuringAFailedReloginKeepsItsPair() async throws {
        let backend = BackendFixture()
        let manager = backend.manager
        SettingsAPIStub.enqueue(BackendFixture.sessionRevoked, for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A9", refresh: "R9"), for: backend.loginURL)
        await manager.setRefreshFailedHandler {
            _ = try? await manager.login(
                studentId: "B11000000", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
            )
            return false
        }

        #expect(await manager.validAccessToken() == nil)

        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R9")
        #expect(await manager.validAccessToken() == "A9")
    }

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

        #expect(await manager.endSession().accessToken == "A9")
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

        #expect(await backend.manager.endSession().accessToken == "A1")
    }

    @Test("a new pair gets two sends of its own")
    func aNewPairStartsTheCountOver() async throws {
        let backend = BackendFixture()
        SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL)
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

    @Test("a sign-out ends the session at once, and only its own calls still carry the account's token")
    func signOutEndsTheSessionButItsCallsGoOut() async throws {
        let backend = BackendFixture()
        let registration = RegistrationFixture(manager: backend.manager)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)
        SettingsAPIStub.enqueue(.init(statusCode: 204, body: Data()), for: registration.unregisterURL)

        let token = await backend.manager.endSession().accessToken

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

        let ending = Task { await manager.endSession().accessToken }
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

        let ending = Task { await manager.endSession().accessToken }
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

        let ending = Task { await manager.endSession().accessToken }
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

        let token = await manager.endSession().accessToken
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

        #expect(await backend.manager.endSession().accessToken == "A0")
        #expect(SettingsAPIStub.requests(for: backend.refreshURL).isEmpty)
    }

    @Test("a sign-out whose refresh is turned down sends no unregister")
    func signOutWithoutATokenSendsNothing() async {
        let backend = BackendFixture()
        let registration = RegistrationFixture(manager: backend.manager)
        SettingsAPIStub.enqueue(BackendFixture.reuseDetected, for: backend.refreshURL)

        let token = await backend.manager.endSession().accessToken
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

        #expect(await manager.endSession().accessToken == nil)
        gate.open()

        await #expect(throws: CancellationError.self) { try await login.value }
        #expect(await !manager.isLoggedIn)
    }

    @Test("a relogin for a refused access token sends nothing once another pair is stored, and signs in while it is not")
    func aReloginForARefusedTokenChecksAfterItsTurn() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture(accessTokenExpiry: Date.now.addingTimeInterval(600))
        let manager = backend.manager
        SettingsAPIStub.enqueue(
            BackendFixture.loginReply(access: "A1", refresh: "R1", heldBy: gate), for: backend.loginURL
        )
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A2", refresh: "R2"), for: backend.loginURL)
        let signIn = Task {
            try await manager.login(
                studentId: "B11000000", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
            )
        }
        try await waitUntil { SettingsAPIStub.requests(for: backend.loginURL).count == 1 }
        let relogin = Task {
            try await manager.login(
                studentId: "B11000000", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios",
                replacing: "A0"
            )
        }
        while await manager.signInsWaiting < 1 { try await Task.sleep(for: .milliseconds(5)) }
        gate.open()

        #expect(try await relogin.value == nil)
        #expect(try await signIn.value != nil)
        #expect(SettingsAPIStub.requests(for: backend.loginURL).count == 1)
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R1")

        let again = try await manager.login(
            studentId: "B11000000", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios",
            replacing: "A1"
        )
        #expect(again != nil)
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R2")
    }

    @Test("a sign-in still waiting for its turn when the account signs out sends nothing")
    func aWaitingSignInASignOutOvertookSendsNothing() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture(signedIn: false)
        let manager = backend.manager
        SettingsAPIStub.enqueue(
            BackendFixture.loginReply(access: "A1", refresh: "R1", heldBy: gate), for: backend.loginURL
        )
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A2", refresh: "R2"), for: backend.loginURL)
        let first = Task {
            try await manager.login(
                studentId: "B11000000", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
            )
        }
        try await waitUntil { SettingsAPIStub.requests(for: backend.loginURL).count == 1 }
        let second = Task {
            try await manager.login(
                studentId: "B11000000", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
            )
        }
        while await manager.signInsWaiting < 1 { try await Task.sleep(for: .milliseconds(5)) }

        await manager.logout()
        gate.open()

        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(SettingsAPIStub.requests(for: backend.loginURL).count == 1)
        #expect(await !manager.isLoggedIn)
    }

    @Test("a sign-in waits for the one before it, so the pair kept is the one the backend issued last")
    func overlappingSignInsKeepTheLastPair() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture(signedIn: false)
        let manager = backend.manager
        SettingsAPIStub.enqueue(
            BackendFixture.loginReply(access: "A1", refresh: "R1", heldBy: gate), for: backend.loginURL
        )
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "A2", refresh: "R2"), for: backend.loginURL)
        let first = Task {
            try await manager.login(
                studentId: "B11000000", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
            )
        }
        try await waitUntil { SettingsAPIStub.requests(for: backend.loginURL).count == 1 }
        let second = Task {
            try await manager.login(
                studentId: "B11000000", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
            )
        }
        while await manager.signInsWaiting < 1 { try await Task.sleep(for: .milliseconds(5)) }

        #expect(SettingsAPIStub.requests(for: backend.loginURL).count == 1)
        gate.open()
        _ = try await (first.value, second.value)

        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == "R2")
        #expect(await manager.validAccessToken() == "A2")
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

        let ending = Task { await manager.endSession().accessToken }
        while await manager.isLoggedIn { try await Task.sleep(for: .milliseconds(5)) }
        gate.open()

        #expect(await ending.value == "A1")
        #expect(await refresh.value == nil)
        #expect(try backend.sentRefreshTokens() == ["R0"])
        #expect(backend.recorder.stored(AuthTokenManager.refreshTokenKey) == nil)
    }

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

        let ending = Task { await manager.endSession().accessToken }
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

        let ending = Task { await manager.endSession().accessToken }
        while await manager.isLoggedIn { try await Task.sleep(for: .milliseconds(5)) }
        gate.open()

        #expect(await ending.value == nil)
        #expect(await refresh.value == nil)
        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
    }

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

        let ending = Task { await manager.endSession().accessToken }
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

        #expect(await backend.manager.endSession().accessToken == nil)

        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
        #expect(!backend.relaunched().hasDepartingSession)
    }

    @Test("a sign-out during the relogin after a 401 sends the refused token no more")
    func signOutDuringTheReloginSendsTheRefusedTokenNoMore() async throws {
        let backend = BackendFixture()
        let manager = backend.manager
        let ending = OSAllocatedUnfairLock<Task<String?, Never>?>(initialState: nil)
        await manager.setRefreshFailedHandler {
            ending.withLock { $0 = Task { await manager.endSession().accessToken } }
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

@Suite("The session a sign-out keeps for its unregister")
struct DepartingSessionTests {
    private static func keptSessions(_ backend: BackendFixture) throws -> [(token: String, uses: Int, baseURL: String?)] {
        guard let json = backend.recorder.stored(AuthTokenManager.departingSessionKey) else { return [] }
        let sessions = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        return try sessions.map { session in
            (
                try #require(session["refreshToken"] as? String), try #require(session["uses"] as? Int),
                session["baseURL"] as? String
            )
        }
    }

    private static func kept(_ backend: BackendFixture) throws -> (token: String, uses: Int, baseURL: String?)? {
        try keptSessions(backend).first
    }

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
        let ending = Task { await backend.manager.endSession().accessToken }
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

        let ending = Task { await manager.endSession().accessToken }
        while await manager.isLoggedIn { try await Task.sleep(for: .milliseconds(5)) }
        gate.open()

        #expect(await ending.value == "A1")
        #expect(await refresh.value == nil)
        #expect(try Self.kept(backend)?.token == "R1")
        #expect(try Self.kept(backend)?.uses == 0)
        #expect(try Self.kept(backend)?.baseURL == backend.baseURL.absoluteString)
    }

    @Test("a sign-out after a sign-in refreshes the sign-in's token, not the pair of a refresh still out from before")
    func aSignOutAfterASignInLeavesTheOlderRefresh() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = BackendFixture()
        let manager = backend.manager
        SettingsAPIStub.enqueue(
            BackendFixture.refreshReply(access: "A1", refresh: "R1", heldBy: gate), for: backend.refreshURL
        )
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "B2", refresh: "BR2"), for: backend.refreshURL)
        // Inside the sign-out's window, so the sign-out refreshes for its unregister.
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1", expiresIn: 60), for: backend.loginURL)
        let refresh = Task { await manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }
        _ = try await manager.login(
            studentId: "B11000000", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )

        let ending = Task { await manager.endSession().accessToken }
        while await manager.isLoggedIn { try await Task.sleep(for: .milliseconds(5)) }
        gate.open()

        #expect(await ending.value == "B2")
        #expect(await refresh.value == nil)
        #expect(try backend.sentRefreshTokens() == ["R0", "BR1"])
        #expect(try Self.kept(backend)?.token == "BR2")
        #expect(try Self.kept(backend)?.uses == 0)
    }

    @Test("a sign-out takes the late pair of its own token's refresh, though an older refresh replies after it")
    func aSignOutTakesTheLatePairOfItsOwnToken() async throws {
        let older = SettingsAPIStub.ReplyGate()
        let newer = SettingsAPIStub.ReplyGate()
        defer { older.open(); newer.open() }
        let backend = BackendFixture()
        let begun = OSAllocatedUnfairLock(initialState: 0)
        let newerEnding = OSAllocatedUnfairLock(initialState: false)
        let released = OSAllocatedUnfairLock(initialState: false)
        // The newer refresh is the second; it holds after storing its result, as a suspended end would.
        let manager = backend.relaunched(following: { backend.baseURL }, beginBackgroundTask: {
            let index = begun.withLock { count in
                count += 1
                return count
            }
            return {
                guard index == 2 else { return }
                newerEnding.withLock { $0 = true }
                while !released.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
            }
        })
        SettingsAPIStub.enqueue(
            BackendFixture.refreshReply(access: "A1", refresh: "R1", heldBy: older), for: backend.refreshURL
        )
        SettingsAPIStub.enqueue(
            BackendFixture.refreshReply(access: "B2", refresh: "BR2", heldBy: newer), for: backend.refreshURL
        )
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1", expiresIn: 0), for: backend.loginURL)
        let olderRefresh = Task { await manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }
        _ = try await manager.login(
            studentId: "B11000000", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
        let newerRefresh = Task { await manager.validAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 2 }

        let ending = Task { await manager.endSession().accessToken }
        while await manager.isLoggedIn { try await Task.sleep(for: .milliseconds(5)) }
        newer.open()
        try await waitUntil { newerEnding.withLock { $0 } }
        older.open()
        #expect(await olderRefresh.value == nil)
        released.withLock { $0 = true }

        #expect(await ending.value == "B2")
        #expect(await newerRefresh.value == nil)
        #expect(try backend.sentRefreshTokens() == ["R0", "BR1"])
        #expect(try Self.kept(backend)?.token == "BR2")
    }

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

    @Test("a session kept on a cleartext backend is retried only while that backend is in use")
    func aCleartextSessionIsRetriedOnlyWhileInUse() async throws {
        let backend = BackendFixture(
            accessTokenExpiry: Date.now.addingTimeInterval(600),
            baseURL: URL(string: "http://settings-stub.invalid/\(UUID().uuidString)/v3")!
        )
        _ = await backend.manager.endSession()
        let unregistered = OSAllocatedUnfairLock(initialState: [URL]())
        let unregister: @MainActor @Sendable (URL) async -> Bool = { url in
            unregistered.withLock { $0.append(url) }
            return true
        }

        await backend.relaunched(at: SettingsAPIStub.uniqueBaseURL()).retryDepartingUnregister(unregister)
        #expect(SettingsAPIStub.requests(for: backend.refreshURL).isEmpty)

        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)
        await backend.relaunched().retryDepartingUnregister(unregister)

        #expect(try backend.sentRefreshTokens() == ["R0"])
        #expect(unregistered.withLock { $0 } == [backend.baseURL])
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

    @Test("a kept session is kept through a status that spends no token", arguments: [400, 403, 404, 408, 422])
    func aStatusThatSpendsNothingKeepsTheSession(status: Int) async throws {
        let backend = await Self.signedOut()
        SettingsAPIStub.enqueue(.init(statusCode: status, body: Data()), for: backend.refreshURL)

        #expect(await backend.relaunched().departingAccessToken() == nil)

        #expect(try Self.kept(backend)?.token == "R0")
        #expect(try Self.kept(backend)?.uses == 0)
    }

    @Test("a sign-in on another backend keeps the session kept on the old one, and the retry sends it there")
    func aSignInElsewhereKeepsTheSessionForItsBackend() async throws {
        let backend = await Self.signedOut()
        let current = SettingsAPIStub.uniqueBaseURL()
        let relaunched = backend.relaunched(at: current)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: current.appendingPathComponent("auth/login"))
        _ = try await relaunched.login(
            studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
        #expect(try Self.kept(backend)?.baseURL == backend.baseURL.absoluteString)
        #expect(relaunched.departingSessionBackends == [backend.baseURL])

        let registration = RegistrationFixture(manager: relaunched, baseURL: current)
        let unregisterURL = backend.baseURL.appendingPathComponent("devices/test-device")
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)
        SettingsAPIStub.enqueue(.init(statusCode: 204, body: Data()), for: unregisterURL)
        await relaunched.retryDepartingUnregister { await registration.service.unregisterDevice(at: $0) }

        let unregister = try #require(SettingsAPIStub.requests(for: unregisterURL).first)
        #expect(unregister.value(forHTTPHeaderField: "Authorization") == "Bearer A1")
        #expect(try Self.kept(backend) == nil)
        #expect(await relaunched.validAccessToken() == "B1")
    }

    @Test("a sign-out during a launch retry on another backend keeps its own session through the retry's writes")
    func aSignOutDuringARetryElsewhereKeepsItsSession() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = await Self.signedOut()
        let current = SettingsAPIStub.uniqueBaseURL()
        let relaunched = backend.relaunched(at: current)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: current.appendingPathComponent("auth/login"))
        _ = try await relaunched.login(
            studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
        let registration = RegistrationFixture(manager: relaunched, baseURL: current)
        let unregisterURL = backend.baseURL.appendingPathComponent("devices/test-device")
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1", heldBy: gate), for: backend.refreshURL)
        SettingsAPIStub.enqueue(.init(statusCode: 204, body: Data()), for: unregisterURL)
        let retry = Task { await relaunched.retryDepartingUnregister { await registration.service.unregisterDevice(at: $0) } }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        #expect(await relaunched.endSession().accessToken == "B1")
        gate.open()
        await retry.value

        #expect(SettingsAPIStub.requests(for: unregisterURL).count == 1)
        #expect(try Self.keptSessions(backend).map(\.token) == ["BR1"])
        #expect(try Self.keptSessions(backend).map(\.baseURL) == [current.absoluteString])
    }

    @Test("a late 401 of a retry that a sign-in and a sign-out overtook leaves the newer sign-out's session")
    func aLateTurnDownLeavesANewerSession() async throws {
        let gate = SettingsAPIStub.ReplyGate()
        defer { gate.open() }
        let backend = await Self.signedOut()
        let manager = backend.relaunched()
        SettingsAPIStub.enqueue(.init(statusCode: 401, body: Data(), gate: gate), for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: backend.loginURL)
        let retry = Task { await manager.departingAccessToken() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }

        _ = try await manager.login(
            studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
        #expect(await manager.endSession().accessToken == "B1")
        gate.open()

        #expect(await retry.value == nil)
        #expect(try Self.keptSessions(backend).map(\.token) == ["BR1"])
    }

    @Test("sign-outs on two backends keep a session for each, and a later launch unregisters from both")
    func twoBackendsKeepASessionEach() async throws {
        let backend = await Self.signedOut()
        let other = SettingsAPIStub.uniqueBaseURL()
        let onOther = backend.relaunched(at: other)
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: other.appendingPathComponent("auth/login"))
        _ = try await onOther.login(
            studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
        #expect(await onOther.endSession().accessToken == "B1")
        #expect(try Self.keptSessions(backend).map(\.token) == ["R0", "BR1"])

        let relaunched = backend.relaunched(at: other)
        let registration = RegistrationFixture(manager: relaunched, baseURL: other)
        let firstUnregister = backend.baseURL.appendingPathComponent("devices/test-device")
        let otherUnregister = other.appendingPathComponent("devices/test-device")
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1"), for: backend.refreshURL)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "B2", refresh: "BR2"), for: other.appendingPathComponent("auth/refresh"))
        SettingsAPIStub.enqueue(.init(statusCode: 204, body: Data()), for: firstUnregister)
        SettingsAPIStub.enqueue(.init(statusCode: 204, body: Data()), for: otherUnregister)
        await relaunched.retryDepartingUnregister { await registration.service.unregisterDevice(at: $0) }

        #expect(SettingsAPIStub.requests(for: firstUnregister).first?.value(forHTTPHeaderField: "Authorization") == "Bearer A1")
        #expect(SettingsAPIStub.requests(for: otherUnregister).first?.value(forHTTPHeaderField: "Authorization") == "Bearer B2")
        #expect(try Self.keptSessions(backend).isEmpty)
    }

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
        let account = await manager.endSession()

        await manager.unregisterDeparting(as: account) { await manager.validAccessToken() == nil }
        #expect(try Self.kept(backend) != nil)

        await manager.unregisterDeparting(as: account) { await manager.validAccessToken() == "A0" }
        #expect(try Self.kept(backend) == nil)
    }

    @Test("the unregister of a sign-out that kept nothing leaves the session an earlier sign-out kept")
    func aSignOutThatKeptNothingForgetsNoEarlierSession() async throws {
        let backend = BackendFixture(accessTokenExpiry: Date.now.addingTimeInterval(600))
        let manager = backend.manager
        await manager.unregisterDeparting(as: await manager.endSession()) { false }

        let keptNothing = await manager.endSession()
        #expect(keptNothing.accessToken == nil)
        await manager.unregisterDeparting(as: keptNothing) { true }

        #expect(try Self.kept(backend)?.token == "R0")
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

    @Test("a sign-out's unregister goes to the backend that issued its session, though the endpoint changed first")
    func theSignOutsUnregisterGoesWhereItsSessionWasIssued() async throws {
        let backend = BackendFixture(accessTokenExpiry: Date.now.addingTimeInterval(600))
        let manager = backend.relaunched(at: SettingsAPIStub.uniqueBaseURL())
        let registration = RegistrationFixture(manager: manager, resolvingAsTheApp: true)
        let unregisterURL = backend.baseURL.appendingPathComponent("devices/test-device")
        SettingsAPIStub.enqueue(.init(statusCode: 204, body: Data()), for: unregisterURL)

        let account = await manager.endSession(on: backend.baseURL)
        await manager.unregisterDeparting(as: account) { await registration.service.unregisterDevice() }

        let unregister = try #require(SettingsAPIStub.requests(for: unregisterURL).first)
        #expect(unregister.value(forHTTPHeaderField: "Authorization") == "Bearer A0")
        #expect(try Self.kept(backend) == nil)
    }

    @Test("a sign-out's unregister keeps its own token and backend after a sign-in and sign-out on another backend")
    func anEarlierSignOutKeepsItsAccount() async throws {
        let backend = BackendFixture(accessTokenExpiry: Date.now.addingTimeInterval(600))
        let other = SettingsAPIStub.uniqueBaseURL()
        let endpoint = OSAllocatedUnfairLock(initialState: backend.baseURL)
        let manager = backend.relaunched(following: { endpoint.withLock { $0 } })
        let registration = RegistrationFixture(manager: manager, resolvingAsTheApp: true)
        let first = await manager.endSession(on: manager.beginSignOut())
        endpoint.withLock { $0 = other }
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: other.appendingPathComponent("auth/login"))
        _ = try await manager.login(
            studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
        #expect(await manager.endSession(on: manager.beginSignOut()).accessToken == "B1")
        let unregisterURL = backend.baseURL.appendingPathComponent("devices/test-device")
        SettingsAPIStub.enqueue(.init(statusCode: 204, body: Data()), for: unregisterURL)

        await manager.unregisterDeparting(as: first) { await registration.service.unregisterDevice() }

        let unregister = try #require(SettingsAPIStub.requests(for: unregisterURL).first)
        #expect(unregister.value(forHTTPHeaderField: "Authorization") == "Bearer A0")
        #expect(SettingsAPIStub.requests(under: other).allSatisfy { $0.httpMethod != "DELETE" })
        #expect(try Self.keptSessions(backend).map(\.token) == ["BR1"])
    }

    @Test("from the moment a sign-out starts, the session's tokens go out no more, and the next sign-in's do")
    func aSignOutHoldsTheTokensAtOnce() async throws {
        let backend = BackendFixture(accessTokenExpiry: Date.now.addingTimeInterval(600))
        let manager = backend.manager
        #expect(await manager.validAccessToken() == "A0")

        #expect(manager.beginSignOut() == backend.baseURL)
        #expect(await manager.validAccessToken() == nil)

        #expect(await manager.endSession().accessToken == "A0")
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: backend.loginURL)
        _ = try await manager.login(
            studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
        )
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
        await SecureStore.$sharedForTesting.withValue(MemoryKeychain.signedIn()) {
            await auth.signInToServices(
                studentId: "B11000000", password: "password", generation: auth.loginGeneration &- 1
            )
        }

        #expect(harvests.value == 0)
        #expect(SettingsAPIStub.requests(for: backend.loginURL).isEmpty)
    }

    @Test("a sign-out during the Moodle step keeps the backend sign-in from going out")
    func aSignOutDuringTheMoodleStepStopsTheBackendSignIn() async throws {
        try await withExclusiveRealDefaults {
            let saved = (Defaults[.ntustCredentialsPresent], SSOLoginService.storedPasswordRefusals)
            defer {
                Defaults[.ntustCredentialsPresent] = saved.0
                SSOLoginService.storedPasswordRefusals = saved.1
            }
            let backend = BackendFixture(signedIn: false)
            let signingIn = SheetSignIn()
            let harvests = CallCount()
            let auth = AuthService(
                keychainHasCredentials: { false },
                notificationCenter: NotificationCenter(),
                moodleTokens: MoodleTokenService(
                    storedCredentials: { nil },
                    // A token that outlives the sign-out, so only the generation stops the backend step.
                    tokens: .init(load: { "moodle-token" }, save: { _ in }, drop: {}),
                    harvest: { _, _ in
                        harvests.increment()
                        await MainActor.run { signingIn.signOut?() }
                        return .init(signature: "", wstoken: "harvested", privatetoken: nil)
                    }
                ),
                endSchoolSession: { _ in }
            )
            #if os(iOS)
            auth.accountNotifications = DeliveredNotificationsStub()
            #endif
            signingIn.signOut = { auth.logout() }
            auth.authTokenManager = backend.manager

            await SecureStore.$sharedForTesting.withValue(MemoryKeychain.signedIn()) {
                await auth.signInToServices(studentId: "B11000000", password: "password", generation: auth.loginGeneration)
            }

            #expect(harvests.value == 1)
            #expect(SettingsAPIStub.requests(for: backend.loginURL).isEmpty)
        }
    }

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
                        await MainActor.run { sheet.task?.cancel() }
                        return .init(signature: "", wstoken: "harvested", privatetoken: nil)
                    }
                ),
                schoolSignIn: { _, _ in true },
                endSchoolSession: { _ in }
            )
            auth.authTokenManager = backend.manager
            let keychain = MemoryKeychain.locked()
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

    enum SignInPath: String, CaseIterable, CustomTestStringConvertible {
        case relogin
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

    private static let unsentRegistration = PushRegistrationSnapshot(
        ptsTokenLength: 0, deviceTokenLength: 6, lastError: "register: x",
        lastAttemptFoundNoSession: true, lastRegisteredAt: nil
    )
}

struct BackendFixture {
    let manager: AuthTokenManager
    let recorder: Recorder
    let baseURL: URL
    let refreshURL: URL
    let loginURL: URL
    let refreshTimeout: TimeInterval

    /// `accessTokenExpiry` is when A0 runs out; the default has it expired. A request the stub
    /// holds must outlast a busy runner's stall, over 88 s in CI, so requests here time out after
    /// ten minutes unless a test sets `refreshTimeout` (https://github.com/tigerduck-app/tigerduck-app/issues/416).
    init(
        signedIn: Bool = true,
        accessTokenExpiry: Date = Date(timeIntervalSince1970: 0),
        refreshTimeout: TimeInterval = 600,
        baseURL: URL = SettingsAPIStub.uniqueBaseURL()
    ) {
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
        manager = Self.manager(endpoint: { baseURL }, recorder: recorder, refreshTimeout: refreshTimeout)
    }

    func relaunched(at baseURL: URL? = nil) -> AuthTokenManager {
        let baseURL = baseURL ?? self.baseURL
        return relaunched(following: { baseURL })
    }

    /// A manager whose endpoint is what `endpoint` answers at each request.
    func relaunched(
        following endpoint: @escaping @Sendable () -> URL,
        beginBackgroundTask: (@Sendable () async -> @Sendable () async -> Void)? = nil
    ) -> AuthTokenManager {
        Self.manager(
            endpoint: endpoint, recorder: recorder, refreshTimeout: refreshTimeout, beginBackgroundTask: beginBackgroundTask
        )
    }

    func refusingRefreshToken(while refused: OSAllocatedUnfairLock<Bool>) -> AuthTokenManager {
        refusingWrites { key, _ in key == AuthTokenManager.refreshTokenKey && refused.withLock { $0 } }
    }

    /// A manager whose Keychain refuses each write `refuses` names; a delete has no value.
    func refusingWrites(_ refuses: @escaping @Sendable (_ key: String, _ value: String?) -> Bool) -> AuthTokenManager {
        let keychain = recorder.tokenStore
        let tokens = AuthTokenManager.TokenStore(
            load: keychain.load,
            save: { key, value in if !refuses(key, value) { keychain.save(key, value) } },
            delete: { key in if !refuses(key, nil) { keychain.delete(key) } },
            confirmedSave: { key, value in
                guard !refuses(key, value) else { return false }
                keychain.save(key, value)
                return true
            },
            confirmedDelete: { key in
                guard !refuses(key, nil) else { return false }
                keychain.delete(key)
                return true
            }
        )
        let baseURL = baseURL
        return Self.manager(endpoint: { baseURL }, recorder: recorder, tokens: tokens, refreshTimeout: refreshTimeout)
    }

    private static func manager(
        endpoint: @escaping @Sendable () -> URL, recorder: Recorder, tokens: AuthTokenManager.TokenStore? = nil,
        refreshTimeout: TimeInterval, beginBackgroundTask: (@Sendable () async -> @Sendable () async -> Void)? = nil
    ) -> AuthTokenManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        config.timeoutIntervalForRequest = 600
        return AuthTokenManager(
            baseURLProvider: endpoint,
            deviceUUID: "test-device",
            session: URLSession(configuration: config),
            tokens: tokens ?? recorder.tokenStore,
            refreshTimeout: refreshTimeout,
            beginBackgroundTask: beginBackgroundTask ?? { recorder.beginBackgroundTask() }
        )
    }

    func sentRefreshTokens() throws -> [String] {
        try SettingsAPIStub.requests(for: refreshURL).map { request in
            let body = try #require(SettingsAPIStub.bodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            return try #require(json["refresh_token"])
        }
    }

    func sentLoginBodies() throws -> [[String: Any]] {
        try SettingsAPIStub.requests(for: loginURL).map { request in
            let body = try #require(SettingsAPIStub.bodyData(from: request))
            return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
    }

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
        access: String, refresh: String, expiresIn: Int = 900, heldBy gate: SettingsAPIStub.ReplyGate? = nil
    ) -> SettingsAPIStub.StubResponse {
        .init(statusCode: 200, body: Data("""
            {"access_token":"\(access)","refresh_token":"\(refresh)","token_type":"Bearer","expires_in":\(expiresIn),\
            "user":{"id":"user-1","student_id":"B11000000","display_name":null},"device_id":"device-1"}
            """.utf8), gate: gate)
    }

    static var reuseDetected: SettingsAPIStub.StubResponse {
        .init(statusCode: 401, body: Data(#"{"detail":"refresh_reuse_detected"}"#.utf8))
    }

    static var sessionRevoked: SettingsAPIStub.StubResponse {
        .init(statusCode: 401, body: Data(#"{"detail":"session_revoked"}"#.utf8))
    }
}

private struct RegistrationFixture {
    let service: PushRegistrationService
    let announceURL: URL
    let registerURL: URL
    let unregisterURL: URL

    /// `resolvingAsTheApp` sends to `PushServerConfig.resolveServerURL()` instead of `baseURL`.
    init(manager: AuthTokenManager, baseURL: URL = SettingsAPIStub.uniqueBaseURL(), resolvingAsTheApp: Bool = false) {
        announceURL = baseURL.appendingPathComponent("devices/anonymous")
        registerURL = baseURL.appendingPathComponent("devices/register")
        unregisterURL = baseURL.appendingPathComponent("devices/test-device")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        service = PushRegistrationService(
            identity: PushIdentity(uuid: "test-device"),
            apiClient: PushAPIClient(
                baseURLProvider: { resolvingAsTheApp ? PushServerConfig.resolveServerURL() : baseURL },
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

    func register() async {
        await service.update(deviceToken: Data([0xAB, 0xCD, 0xEF]))
        await service.awaitPendingRegistration()
    }
}

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

@MainActor
private final class SheetSignIn {
    var task: Task<Bool, Never>?
    var signOut: (() -> Void)?
}

private nonisolated final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private extension MoodleTokenService {
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

private func withNoSyncPreferencesPending<T>(_ body: () async throws -> T) async rethrows -> T {
    try await withExclusiveRealDefaults {
        let saved = Defaults[.syncPreferencesPushPending]
        Defaults[.syncPreferencesPushPending] = false
        defer { Defaults[.syncPreferencesPushPending] = saved }
        return try await body()
    }
}

private func withNoPasswordRefusals<T>(_ body: () async throws -> T) async rethrows -> T {
    try await withExclusiveRealDefaults {
        let saved = SSOLoginService.storedPasswordRefusals
        SSOLoginService.forgetStoredPasswordRefusals()
        defer { SSOLoginService.storedPasswordRefusals = saved }
        return try await body()
    }
}

nonisolated final class MemoryKeychain: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    static func signedIn(withMoodleToken: Bool = true) -> MemoryKeychain {
        let keychain = MemoryKeychain()
        keychain.unlock(withMoodleToken: withMoodleToken)
        return keychain
    }

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
