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
    /// Returns a `Bearer <token>` string for the v3 JWT auth flow, or `nil`
    /// when the user is not logged in (unauthenticated requests are still
    /// attempted so the server can respond with 401 rather than silently
    /// dropping calls before auth is wired up end-to-end).
    private let authHeaderProvider: @Sendable () async -> String?
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.API")

    /// `baseURLProvider` is re-evaluated on every request so a Debug build
    /// that switches the API endpoint at runtime (via `DebugEndpointView`)
    /// takes effect on the next push call without an app relaunch.
    ///
    /// `authHeaderProvider` is an async closure so callers can supply the
    /// `AuthTokenManager.authorizationHeader()` actor method directly. The
    /// default closure returns `nil` (no auth header), matching the
    /// pre-v3 behaviour for existing tests and Debug builds that have not
    /// yet wired up an `AuthTokenManager`.
    init(
        baseURLProvider: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        session: URLSession? = nil,
        authHeaderProvider: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.baseURLProvider = baseURLProvider
        self.session = session ?? Self.defaultSession()
        self.authHeaderProvider = authHeaderProvider
    }

    // MARK: - Public surface

    func registerDevice(_ request: PushAPI.DeviceRegisterRequest) async throws -> PushAPI.DeviceRegisterResponse {
        try await post(path: "/devices/register", body: request, returning: PushAPI.DeviceRegisterResponse.self)
    }

    func unregisterDevice(deviceId: String) async throws {
        let safeDevice = Self.percentEncoded(deviceId)
        try await delete(path: "/devices/\(safeDevice)")
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
        cloudSyncEnabled: Bool? = nil
    ) async throws -> PushAPI.DevicePreferencesResponse {
        let body = PushAPI.DevicePreferencesRequest(
            serverPushEnabled: serverPushEnabled,
            syncCourses: syncCourses,
            syncCourseColors: syncCourseColors,
            syncCourseNames: syncCourseNames,
            syncAssignments: syncAssignments,
            cloudSyncEnabled: cloudSyncEnabled
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

    /// v3: device identity comes from the JWT; only `sourceId` is needed in the path.
    func cancelSchedule(sourceId: String) async throws {
        let safeSource = Self.percentEncoded(sourceId)
        try await delete(path: "/schedule/\(safeSource)")
    }

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

    func patchAssignmentOverride(
        moodleAssignmentId: String,
        localStatus: String
    ) async throws -> PushAPI.AssignmentOverrideResponse {
        let body = PushAPI.AssignmentOverrideRequest(localStatus: localStatus)
        return try await patch(
            path: "/sync/assignments/\(moodleAssignmentId)/override",
            body: body,
            returning: PushAPI.AssignmentOverrideResponse.self
        )
    }

    func patchCourseOverride(
        moodleCourseId: String,
        colorHex: String? = nil,
        customName: String? = nil,
        locale: String? = nil
    ) async throws -> PushAPI.CourseOverrideResponse {
        let body = PushAPI.CourseOverrideRequest(
            colorHex: colorHex,
            customName: customName,
            locale: locale
        )
        return try await patch(
            path: "/sync/courses/\(moodleCourseId)/override",
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

    func deleteAllCourses() async throws {
        try await delete(path: "/sync/courses")
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
        await applyAuth(to: &request)
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
        await applyAuth(to: &request)
        let data = try await execute(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PushAPIError.decodingFailed(NSError(domain: "PushAPI", code: -1))
        }
        return json
    }

    /// Health check. Intentionally unauthenticated — the push server's
    /// `/ping` is public so connectivity / TLS / DNS can be diagnosed
    /// without needing the shared secret.
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
            logger.error("Push.API decode failed path=\(path, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw PushAPIError.decodingFailed(error)
        }
    }

    private func postExpectingNoBody<Request: Encodable>(
        path: String,
        body: Request
    ) async throws -> Data {
        let request = try await makePostRequest(path: path, body: body)
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
            logger.error("Push.API decode failed path=\(path, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw PushAPIError.decodingFailed(error)
        }
    }

    private func delete(path: String) async throws {
        let baseURL = baseURLProvider()
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        await applyAuth(to: &request)
        _ = try await execute(request)
    }

    private func makePostRequest<Request: Encodable>(path: String, body: Request) async throws -> URLRequest {
        let baseURL = baseURLProvider()
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await applyAuth(to: &request)
        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw PushAPIError.encodingFailed(error)
        }
        return request
    }

    /// Attach the `Authorization: Bearer <token>` header when the
    /// `authHeaderProvider` returns a non-nil value. No-op when the user
    /// is not logged in or the provider is not wired (e.g. unit tests).
    private func applyAuth(to request: inout URLRequest) async {
        guard let header = await authHeaderProvider(), !header.isEmpty else { return }
        request.setValue(header, forHTTPHeaderField: "Authorization")
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PushAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(512), encoding: .utf8) ?? ""
            logger.error("Push.API \(http.statusCode, privacy: .public) \(request.url?.path ?? "", privacy: .public): \(snippet, privacy: .private)")
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
        // Strict allowlist: alphanumerics + a few unreserved punctuation.
        // `urlPathAllowed` keeps `; , : @ & = + $`, several of which break
        // parsers that treat `;` as matrix params or `&` as query
        // separators. Keep `-_.~` because RFC 3986 explicitly marks them
        // unreserved, and dashes are common in source-id formatting.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        // Encoder fallback returns "" rather than the raw value: in the
        // (vanishingly rare) UTF-16 surrogate-pair failure mode, shipping
        // unencoded bytes into the URL path could path-inject. An empty
        // segment yields a clean 404 instead.
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

    var errorDescription: String? {
        switch self {
        case .encodingFailed(let error): return "Push encode failed: \(error.localizedDescription)"
        case .decodingFailed(let error): return "Push decode failed: \(error.localizedDescription)"
        case .invalidResponse: return "Push server returned a non-HTTP response."
        case .httpStatus(let code, let body): return "Push server returned HTTP \(code): \(body)"
        }
    }
}

// ISO-8601 decoding helpers live in `Extensions/JSONDecoder+ISO8601.swift`
// so every HTTP client in the app shares the same parsing behaviour.
