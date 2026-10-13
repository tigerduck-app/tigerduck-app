// `AuthTokenManager` through `SettingsAPIStub`. The backend rotates the refresh token on every
// refresh, redeems the old one once more within 60 s, and takes any later reuse for theft
// (https://github.com/tigerduck-app/tigerduck-app/issues/375).
import Foundation
import Testing
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
                studentId: "B11000000", password: "", moodleToken: "moodle-token",
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

    static func refreshReply(access: String, refresh: String) -> SettingsAPIStub.StubResponse {
        .init(statusCode: 200, body: Data("""
            {"access_token":"\(access)","refresh_token":"\(refresh)","token_type":"Bearer","expires_in":900}
            """.utf8))
    }

    static func loginReply(access: String, refresh: String) -> SettingsAPIStub.StubResponse {
        .init(statusCode: 200, body: Data("""
            {"access_token":"\(access)","refresh_token":"\(refresh)","token_type":"Bearer","expires_in":900,\
            "user":{"id":"user-1","student_id":"B11000000","display_name":null},"device_id":"device-1"}
            """.utf8))
    }

    static var reuseDetected: SettingsAPIStub.StubResponse {
        .init(statusCode: 401, body: Data(#"{"detail":"refresh_reuse_detected"}"#.utf8))
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
