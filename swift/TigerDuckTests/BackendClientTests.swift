import Foundation
import os
import Testing
@testable import TigerDuck

@MainActor
struct BackendClientTests {
    private static func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        config.timeoutIntervalForRequest = 600
        return URLSession(configuration: config)
    }

    @Test("A path segment is encoded once, with a course number's slash kept inside its segment")
    func segmentsAreEncodedOnce() throws {
        let base = try #require(URL(string: "https://backend.stub.invalid/v4"))

        let url = BackendClient.url(base: base, path: ["sync", "courses", "client:1151:AB/12 課", "override"])

        #expect(url?.absoluteString
            == "https://backend.stub.invalid/v4/sync/courses/client:1151:AB%2F12%20%E8%AA%B2/override")
    }

    @Test("An endpoint stored for /v3, as an earlier build kept it, sends to /v4 on the same server")
    func aV3EndpointSendsToV4() throws {
        let stored = try #require(URL(string: "http://192.168.1.5:40000/v3/"))

        #expect(BackendClient.url(base: stored, path: ["sync", "full"])?.absoluteString
            == "http://192.168.1.5:40000/v4/sync/full")
        #expect(AuthTokenManager.isSameBackend(stored, BackendClient.apiBase(stored)))
    }

    @Test("A colour edit of a course whose number holds a slash reaches the backend's one course key")
    func courseKeyWithASlashReachesItsCourse() async throws {
        let base = SettingsAPIStub.uniqueBaseURL()
        let url = try #require(URL(string: base.absoluteString + "/sync/courses/client:1151:AB%2F12/override"))
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(##"{"color_hex":"#FF6B6B","applied":["color_hex"]}"##.utf8)), for: url)
        let client = PushAPIClient(baseURLProvider: { base }, session: Self.stubSession(), authHeaderProvider: { "Bearer A0" })

        let reply = try await client.patchCourseOverride(
            courseKey: "client:1151:AB/12", colorHex: "#FF6B6B", customName: nil, locale: nil, madeAt: Date(), for: testSignIn
        )

        #expect(reply.applied == ["color_hex"])
        #expect(SettingsAPIStub.requests(for: url).count == 1)
    }

    private static let invalidToken = SettingsAPIStub.StubResponse(
        statusCode: 401, body: Data(#"{"error":"invalid_access_token","message":"expired"}"#.utf8)
    )
    private static let revision = SettingsAPIStub.StubResponse(statusCode: 200, body: Data(#"{"revision":7}"#.utf8))

    @Test("Two requests refused at once spend one refresh, and each goes again once with the new token")
    func concurrentRefusalsSpendOneRefresh() async throws {
        let backend = BackendFixture(accessTokenExpiry: Date().addingTimeInterval(3600))
        let url = backend.baseURL.appendingPathComponent("sync/revision")
        let refreshed = SettingsAPIStub.ReplyGate()
        SettingsAPIStub.enqueue(Self.invalidToken, for: url)
        SettingsAPIStub.enqueue(Self.invalidToken, for: url)
        SettingsAPIStub.enqueue(Self.revision, for: url)
        SettingsAPIStub.enqueue(Self.revision, for: url)
        SettingsAPIStub.enqueue(BackendFixture.refreshReply(access: "A1", refresh: "R1", heldBy: refreshed), for: backend.refreshURL)
        let client = PushAPIClient(
            backend: BackendClient(baseURL: { backend.baseURL }, session: Self.stubSession(), auth: backend.manager.backendAuth)
        )

        let first = Task { try await client.fetchRevision() }
        let second = Task { try await client.fetchRevision() }
        try await waitUntil { SettingsAPIStub.requests(for: backend.refreshURL).count == 1 }
        refreshed.open()

        #expect(try await first.value == 7)
        #expect(try await second.value == 7)
        #expect(try backend.sentRefreshTokens() == ["R0"])
        let tokens = SettingsAPIStub.requests(for: url).map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(tokens.filter { $0 == "Bearer A0" }.count == 2)
        #expect(tokens.filter { $0 == "Bearer A1" }.count == 2)
    }

    @Test("A refresh token goes out at most twice, as before /v4; then the client asks for a sign-in instead")
    func refreshBudgetThenSignIn() async throws {
        let backend = BackendFixture(accessTokenExpiry: Date().addingTimeInterval(3600))
        let url = backend.baseURL.appendingPathComponent("sync/revision")
        SettingsAPIStub.enqueue(Self.invalidToken, for: url)
        for _ in 0..<2 { SettingsAPIStub.enqueue(.noReply, for: backend.refreshURL) }
        let signIns = OSAllocatedUnfairLock(initialState: 0)
        await backend.manager.setRefreshFailedHandler { _ in
            signIns.withLock { $0 += 1 }
            return false
        }
        let client = PushAPIClient(
            backend: BackendClient(baseURL: { backend.baseURL }, session: Self.stubSession(), auth: backend.manager.backendAuth)
        )

        await #expect(throws: PushAPIError.self) { try await client.fetchRevision() }
        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
        #expect(signIns.withLock { $0 } == 0)

        await #expect(throws: PushAPIError.self) { try await client.fetchRevision() }
        #expect(try backend.sentRefreshTokens() == ["R0", "R0"])
        #expect(signIns.withLock { $0 } == 1)
        #expect(SettingsAPIStub.requests(for: url).count == 1)
    }

    @Test("A 401 that lands after a sign-out and another account's sign-in does not go again as that account")
    func aRefusalAfterAnotherSignInIsNotReplayed() async throws {
        let backend = BackendFixture(accessTokenExpiry: Date().addingTimeInterval(3600))
        let url = backend.baseURL.appendingPathComponent("sync/revision")
        let refusal = SettingsAPIStub.ReplyGate()
        var held = Self.invalidToken
        held.gate = refusal
        SettingsAPIStub.enqueue(held, for: url)
        SettingsAPIStub.enqueue(Self.revision, for: url)
        let client = PushAPIClient(
            backend: BackendClient(baseURL: { backend.baseURL }, session: Self.stubSession(), auth: backend.manager.backendAuth)
        )

        let fetch = Task { try await client.fetchRevision() }
        try await waitUntil { SettingsAPIStub.requests(for: url).count == 1 }
        await backend.manager.logout()
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: backend.loginURL)
        _ = try await backend.manager.login(
            studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios",
            for: SignInSeries().currentSignIn
        )
        refusal.open()

        await #expect(throws: PushAPIError.self) { try await fetch.value }
        #expect(SettingsAPIStub.requests(for: url).map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer A0"])
    }

    private static func signInAgain(_ backend: BackendFixture, after signIns: SignInSeries) async throws {
        await backend.manager.logout()
        signIns.end()
        SettingsAPIStub.enqueue(BackendFixture.loginReply(access: "B1", refresh: "BR1"), for: backend.loginURL)
        _ = try await backend.manager.login(
            studentId: "B11000001", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios",
            for: signIns.currentSignIn
        )
    }

    @Test("A send built for a sign-in that has ended does not go out with the next sign-in's token")
    func aSendOfAnEndedSignInIsNotSent() async throws {
        let signIns = SignInSeries()
        let departing = signIns.currentSignIn
        let backend = BackendFixture(accessTokenExpiry: Date().addingTimeInterval(3600), signIn: departing)
        let url = backend.baseURL.appendingPathComponent("sync/assignments/upload")
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data("{}".utf8)), for: url)
        let client = PushAPIClient(
            backend: BackendClient(baseURL: { backend.baseURL }, session: Self.stubSession(), auth: backend.manager.backendAuth)
        )
        try await Self.signInAgain(backend, after: signIns)

        await #expect(throws: PushAPIError.self) {
            try await client.uploadAssignments(PushAPI.AssignmentUploadRequest(assignments: []), for: departing)
        }
        #expect(SettingsAPIStub.requests(for: url).isEmpty)
    }

    @Test("A send refused after its sign-in ended does not go again with the next sign-in's token")
    func aSendRefusedAcrossASignOutIsNotReplayed() async throws {
        let signIns = SignInSeries()
        let departing = signIns.currentSignIn
        let backend = BackendFixture(accessTokenExpiry: Date().addingTimeInterval(3600), signIn: departing)
        let url = backend.baseURL.appendingPathComponent("sync/assignments/upload")
        let refusal = SettingsAPIStub.ReplyGate()
        var held = Self.invalidToken
        held.gate = refusal
        SettingsAPIStub.enqueue(held, for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data("{}".utf8)), for: url)
        let client = PushAPIClient(
            backend: BackendClient(baseURL: { backend.baseURL }, session: Self.stubSession(), auth: backend.manager.backendAuth)
        )

        let upload = Task { try await client.uploadAssignments(PushAPI.AssignmentUploadRequest(assignments: []), for: departing) }
        try await waitUntil { SettingsAPIStub.requests(for: url).count == 1 }
        try await Self.signInAgain(backend, after: signIns)
        refusal.open()

        await #expect(throws: PushAPIError.self) { try await upload.value }
        #expect(SettingsAPIStub.requests(for: url).map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer A0"])
    }

    @Test("A session the backend ended signs in again without spending a refresh")
    func endedSessionSignsInAgain() async throws {
        let backend = BackendFixture(accessTokenExpiry: Date().addingTimeInterval(3600))
        let url = backend.baseURL.appendingPathComponent("sync/revision")
        SettingsAPIStub.enqueue(BackendFixture.sessionRevoked, for: url)
        let refused = OSAllocatedUnfairLock(initialState: [String]())
        await backend.manager.setSignInAgainHandler { token, _ in
            refused.withLock { $0.append(token) }
            return false
        }
        let client = PushAPIClient(
            backend: BackendClient(baseURL: { backend.baseURL }, session: Self.stubSession(), auth: backend.manager.backendAuth)
        )

        await #expect(throws: PushAPIError.self) { try await client.fetchRevision() }

        #expect(refused.withLock { $0 } == ["A0"])
        #expect(SettingsAPIStub.requests(for: backend.refreshURL).isEmpty)
    }
}
