import Foundation
import os

/// URLSession-based client for the TigerDuck push server.
///
/// Stateless helpers — safe to recreate per call. Uses a shared ephemeral
/// session so cookies / caches do not leak across app launches. JSON uses
/// ISO-8601 with fractional seconds for Date, matching what the Python
/// server emits from `datetime.isoformat()`.
final class PushAPIClient: Sendable {
    private let baseURLProvider: @Sendable () -> URL
    private let session: URLSession
    /// Returns a `Bearer <token>` string for the v3 JWT auth flow, or `nil` with no usable
    /// session; `AuthTokenManager` first signs in when there is none. A request that needs a
    /// session is then not sent (`PushAPIError.notSignedIn`): it could only be refused.
    private let authHeaderProvider: @Sendable () async -> String?
    /// Where failure statuses go. A test that answers 410 passes its own gate, since the shared
    /// one latches for the whole process.
    private let versionGate: APIVersionGate
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.API")

    /// `baseURLProvider` is re-evaluated on every request, so an endpoint
    /// switched at runtime (`DebugEndpointView`) applies to the next push
    /// call without an app relaunch.
    ///
    /// `authHeaderProvider` is async so callers can pass the
    /// `AuthTokenManager.authorizationHeader()` actor method directly. The
    /// default returns `nil`, so only the requests that need no session go
    /// out, for builds that have no `AuthTokenManager`.
    init(
        baseURLProvider: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        session: URLSession? = nil,
        authHeaderProvider: @escaping @Sendable () async -> String? = { nil },
        versionGate: APIVersionGate? = nil
    ) {
        self.baseURLProvider = baseURLProvider
        self.session = session ?? Self.defaultSession()
        self.authHeaderProvider = authHeaderProvider
        self.versionGate = versionGate ?? .shared
    }

    // MARK: - Public surface

    func registerDevice(_ request: PushAPI.DeviceRegisterRequest) async throws -> PushAPI.DeviceRegisterResponse {
        try await post(path: "/devices/register", body: request, returning: PushAPI.DeviceRegisterResponse.self)
    }

    /// Register the device itself, with no account attached.
    ///
    /// Unauthenticated by design — there is no session to authenticate with
    /// when this matters. It goes without a Bearer header, so it never waits
    /// for a sign-in; the server keys purely on `device_id`, which is what
    /// lets the same call be made on every launch regardless of sign-in state.
    func registerAnonymousDevice(_ request: PushAPI.AnonymousDeviceRequest) async throws {
        _ = try await postExpectingNoBody(path: "/devices/anonymous", body: request, authenticated: false)
    }

    func unregisterDevice(deviceId: String) async throws {
        let safeDevice = Self.percentEncoded(deviceId)
        try await delete(path: "/devices/\(safeDevice)")
    }

    /// PUT the user's "notify me anyway" exception for one holiday.
    ///
    /// Authenticated: the holiday itself is public and comes from
    /// `/v3/calendar/semesters`, but the exception belongs to an account.
    func putHolidayOverride(holidayID: Int, notify: Bool) async throws {
        var request = try await makePostRequest(
            path: "/sync/holiday-overrides/\(holidayID)",
            body: PushAPI.HolidayOverrideRequest(notify: notify)
        )
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        _ = try await execute(request)
    }

    /// Whether there is a session to authenticate a request with, after the sign-in
    /// `authHeaderProvider` tries when there is none.
    ///
    /// Callers that have both an authenticated and an unauthenticated way
    /// to do the same thing need to pick one up front rather than firing
    /// the authenticated call and reading a 401 as the answer — a 401 is
    /// also what a revoked or expired session looks like, and those two
    /// deserve different handling.
    func hasAuthSession() async -> Bool {
        await authHeaderProvider() != nil
    }

    /// PATCH the user-facing server-push opt-out. Called from the Settings
    /// toggle so the change propagates without waiting for the next
    /// `/devices/register` call.
    func updateDevicePreferences(
        deviceId: String,
        serverPushEnabled: Bool? = nil,
        syncCourses: Bool? = nil,
        syncCourseColors: Bool? = nil,
        syncCourseNames: Bool? = nil,
        syncAssignments: Bool? = nil,
        syncAssignmentReminders: Bool? = nil,
        syncLiveActivity: Bool? = nil,
        cloudSyncEnabled: Bool? = nil,
        bulletinPushEnabled: Bool? = nil
    ) async throws -> PushAPI.DevicePreferencesResponse {
        let body = PushAPI.DevicePreferencesRequest(
            serverPushEnabled: serverPushEnabled,
            syncCourses: syncCourses,
            syncCourseColors: syncCourseColors,
            syncCourseNames: syncCourseNames,
            syncAssignments: syncAssignments,
            syncAssignmentReminders: syncAssignmentReminders,
            syncLiveActivity: syncLiveActivity,
            cloudSyncEnabled: cloudSyncEnabled,
            bulletinPushEnabled: bulletinPushEnabled
        )
        let safeDevice = Self.percentEncoded(deviceId)
        return try await patch(
            path: "/devices/\(safeDevice)/preferences",
            body: body,
            returning: PushAPI.DevicePreferencesResponse.self
        )
    }

    func syncSchedule(_ request: PushAPI.ScheduleSyncRequest) async throws -> PushAPI.ScheduleSyncResponse {
        try await post(path: "/schedule/sync", body: request, returning: PushAPI.ScheduleSyncResponse.self)
    }

    #if os(iOS)
    func registerLiveActivityToken(
        _ request: PushAPI.LiveActivityRegisterV3Request
    ) async throws -> PushAPI.LiveActivityTokenRegisterResponse {
        try await post(
            path: "/live-activities/register",
            body: request,
            returning: PushAPI.LiveActivityTokenRegisterResponse.self
        )
    }
    #endif

    // MARK: - Credential refresh

    func updateCredentials(
        moodleToken: String,
        moodlePrivateToken: String?
    ) async throws -> PushAPI.UpdateCredentialsResponse {
        let body = PushAPI.UpdateCredentialsRequest(
            moodleToken: moodleToken,
            moodlePrivateToken: moodlePrivateToken
        )
        return try await patch(
            path: "/auth/credentials",
            body: body,
            returning: PushAPI.UpdateCredentialsResponse.self
        )
    }

    // MARK: - Override sync

    /// The reply is not read: the backend answers a cleared mark (`"none"`) with
    /// `{"deleted": true}` rather than the override row, and no caller needs either.
    func patchAssignmentOverride(
        moodleAssignmentId: String,
        localStatus: String
    ) async throws {
        var request = try await makePostRequest(
            path: "/sync/assignments/\(moodleAssignmentId)/override",
            body: PushAPI.AssignmentOverrideRequest(localStatus: localStatus)
        )
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        _ = try await execute(request)
    }

    /// `moodleId` is the course's Moodle idnumber, or `{semester}{courseNo}` for a hand-added
    /// course; `moodleCourseId` is its numeric Moodle id.
    func patchCourseOverride(
        moodleId: String,
        colorHex: String? = nil,
        customName: String? = nil,
        locale: String? = nil,
        ignoreAssignments: Bool? = nil,
        moodleCourseId: Int? = nil
    ) async throws -> PushAPI.CourseOverrideResponse {
        let body = PushAPI.CourseOverrideRequest(
            colorHex: colorHex,
            customName: customName,
            locale: locale,
            ignoreAssignments: ignoreAssignments,
            moodleCourseId: moodleCourseId
        )
        return try await patch(
            path: "/sync/courses/\(moodleId)/override",
            body: body,
            returning: PushAPI.CourseOverrideResponse.self
        )
    }

    // MARK: - Course upload

    /// Fire-and-forget upload of the user's enrolled course list so the
    /// backend can populate its `courses` table for cross-device sync,
    /// analytics, and course-search indexing.
    func uploadCourses(_ request: PushAPI.CourseUploadRequest) async throws {
        _ = try await postExpectingNoBody(path: "/sync/courses/upload", body: request)
    }

    /// `semester` nil wipes every term (full reset); otherwise only that
    /// term's rows and tombstones go.
    func deleteAllCourses(semester: String? = nil) async throws {
        var components = URLComponents()
        components.path = "/sync/courses"
        if let semester {
            components.queryItems = [URLQueryItem(name: "semester", value: semester)]
        }
        try await delete(path: components.string ?? "/sync/courses")
    }

    func deleteCourse(courseKey: String) async throws {
        try await delete(path: "/sync/courses/\(courseKey)")
    }

    // MARK: - Assignment upload

    /// Fire-and-forget upload of the user's current assignment list so the
    /// backend can populate its `assignments` table for cross-device sync
    /// and notification scheduling.
    func uploadAssignments(_ request: PushAPI.AssignmentUploadRequest) async throws {
        _ = try await postExpectingNoBody(path: "/sync/assignments/upload", body: request)
    }

    // MARK: - Sync

    /// Lightweight revision check. Returns the current server-side revision
    /// number so the caller can decide whether a full sync is needed.
    func fetchRevision() async throws -> Int {
        let baseURL = baseURLProvider()
        let url = baseURL.appendingPathComponent("sync/revision")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await applyAuth(to: &request)
        let data = try await execute(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revision = json["revision"] as? Int else {
            throw PushAPIError.decodingFailed(
                NSError(domain: "PushAPI", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Missing 'revision' in response"])
            )
        }
        return revision
    }

    func fetchFullSync() async throws -> [String: Any] {
        let baseURL = baseURLProvider()
        let url = baseURL.appendingPathComponent("sync/full")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await applyAuth(to: &request)
        let data = try await execute(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PushAPIError.decodingFailed(NSError(domain: "PushAPI", code: -1))
        }
        return json
    }

    /// The changes after `sinceRevision`. Once the server has compacted them it answers 410
    /// `sync_revision_expired`, thrown as `syncRevisionExpired` and kept from `versionGate`,
    /// which would read it as a retired API and latch the update-required screen.
    func fetchChanges(sinceRevision: Int) async throws -> PushAPI.SyncChangesPage {
        let url = baseURLProvider().appendingPathComponent("sync")
            .appending(queryItems: [URLQueryItem(name: "since_revision", value: String(sinceRevision))])
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await applyAuth(to: &request)
        let data = try await execute(request, expectedFailure: Self.revisionExpired)
        do {
            return try Self.decoder.decode(PushAPI.SyncChangesPage.self, from: data)
        } catch {
            logger.error("Push.API decode failed path=/sync error=\(String(describing: error), privacy: .private)")
            throw PushAPIError.decodingFailed(error)
        }
    }

    private static func revisionExpired(statusCode: Int, body: Data) -> PushAPIError? {
        guard statusCode == 410,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["error"] as? String == "sync_revision_expired"
        else { return nil }
        return .syncRevisionExpired
    }

    /// Health check, sent without auth: the push server's `/ping` is public
    /// so connectivity, TLS and DNS can be diagnosed without a Bearer token.
    func ping() async throws {
        let url = baseURLProvider().appendingPathComponent("ping")
        _ = try await execute(URLRequest(url: url))
    }

    // MARK: - Internals

    private func post<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request,
        returning: Response.Type
    ) async throws -> Response {
        var request = try await makePostRequest(path: path, body: body)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await execute(request)
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            logger.error("Push.API decode failed path=\(path, privacy: .public) error=\(String(describing: error), privacy: .private)")
            throw PushAPIError.decodingFailed(error)
        }
    }

    private func postExpectingNoBody<Request: Encodable>(
        path: String,
        body: Request,
        authenticated: Bool = true
    ) async throws -> Data {
        let request = try await makePostRequest(path: path, body: body, authenticated: authenticated)
        return try await execute(request)
    }

    private func patch<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request,
        returning: Response.Type
    ) async throws -> Response {
        var request = try await makePostRequest(path: path, body: body)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await execute(request)
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            logger.error("Push.API decode failed path=\(path, privacy: .private) error=\(String(describing: error), privacy: .private)")
            throw PushAPIError.decodingFailed(error)
        }
    }

    private func delete(path: String) async throws {
        let baseURL = baseURLProvider()
        // `path` may carry a query string; appendingPathComponent would
        // percent-escape the `?`, so splice it back on after the join.
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var url = baseURL.appendingPathComponent(parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        if parts.count == 2, let withQuery = URL(string: url.absoluteString + "?" + parts[1]) {
            url = withQuery
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        try await applyAuth(to: &request)
        _ = try await execute(request)
    }

    private func makePostRequest<Request: Encodable>(
        path: String,
        body: Request,
        authenticated: Bool = true
    ) async throws -> URLRequest {
        let baseURL = baseURLProvider()
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated { try await applyAuth(to: &request) }
        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw PushAPIError.encodingFailed(error)
        }
        return request
    }

    private func applyAuth(to request: inout URLRequest) async throws {
        guard let header = await authHeaderProvider(), !header.isEmpty else {
            throw PushAPIError.notSignedIn
        }
        request.setValue(header, forHTTPHeaderField: "Authorization")
    }

    private func execute(
        _ request: URLRequest,
        expectedFailure: (_ statusCode: Int, _ body: Data) -> PushAPIError? = { _, _ in nil }
    ) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PushAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let expected = expectedFailure(http.statusCode, data) { throw expected }
            let snippet = String(data: data.prefix(512), encoding: .utf8) ?? ""
            logger.error("Push.API \(http.statusCode, privacy: .public) \(request.url?.path ?? "", privacy: .private): \(snippet, privacy: .private)")
            versionGate.note(statusCode: http.statusCode)
            throw PushAPIError.httpStatus(http.statusCode, body: snippet)
        }
        return data
    }

    // MARK: - Factory helpers

    private static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            "User-Agent": "TigerDuck-iOS/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"
        ]
        return URLSession(configuration: config)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSecondsFallback
        return decoder
    }()

    private static func percentEncoded(_ value: String) -> String {
        // Not `urlPathAllowed`: it keeps `; , : @ & = + $`, and some parsers
        // read `;` as matrix params or `&` as a query separator. `-_.~` stay
        // because RFC 3986 marks them unreserved; source ids often use dashes.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        // On failure (a rare UTF-16 surrogate-pair case) return "", not the
        // raw value: unencoded bytes in the URL path could path-inject, while
        // an empty segment yields a clean 404.
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            assertionFailure("percentEncoded failed for value of length \(value.count)")
            return ""
        }
        return encoded
    }
}

enum PushAPIError: Error, LocalizedError {
    case encodingFailed(Error)
    case decodingFailed(Error)
    case invalidResponse
    case httpStatus(Int, body: String)
    /// The change feed no longer holds the changes asked for; only a full sync catches up.
    case syncRevisionExpired
    /// A request that needs a session got no access token, so it was not sent.
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .encodingFailed(let error): return "Push encode failed: \(error.localizedDescription)"
        case .decodingFailed(let error): return "Push decode failed: \(error.localizedDescription)"
        case .invalidResponse: return "Push server returned a non-HTTP response."
        case .httpStatus(let code, let body): return "Push server returned HTTP \(code): \(body)"
        case .syncRevisionExpired: return "Push server has compacted the changes asked for."
        case .notSignedIn: return String(localized: "common_auto_sign_in_failed")
        }
    }
}

// ISO-8601 decoding helpers live in `Extensions/JSONDecoder+ISO8601.swift`
// so every HTTP client in the app shares the same parsing behaviour.
