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
    private let authHeaderProvider: @Sendable () async -> String?
    private let versionGate: APIVersionGate
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.API")

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

    func registerDevice(_ request: PushAPI.DeviceRegisterRequest) async throws -> PushAPI.DeviceRegisterResponse {
        try await post(path: "/devices/register", body: request, returning: PushAPI.DeviceRegisterResponse.self)
    }

    func registerAnonymousDevice(_ request: PushAPI.AnonymousDeviceRequest) async throws {
        _ = try await postExpectingNoBody(path: "/devices/anonymous", body: request, authenticated: false)
    }

    func unregisterDevice(deviceId: String, at baseURL: URL? = nil) async throws {
        let safeDevice = Self.percentEncoded(deviceId)
        try await delete(path: "/devices/\(safeDevice)", at: baseURL)
    }

    func putHolidayOverride(holidayID: Int, notify: Bool) async throws {
        var request = try await makePostRequest(
            path: "/sync/holiday-overrides/\(holidayID)",
            body: PushAPI.HolidayOverrideRequest(notify: notify)
        )
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        _ = try await execute(request)
    }

    func hasAuthSession() async -> Bool {
        await authHeaderProvider() != nil
    }

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

    /// An upload with `adds` goes under protocol 2; one the backend refuses as stamped ahead of its
    /// clock goes again with `forceKeys` alone, which counts from when it arrives.
    func uploadCourses(_ request: PushAPI.CourseUploadRequest) async throws {
        guard request.adds != nil else {
            _ = try await postExpectingNoBody(path: "/sync/courses/upload", body: request)
            return
        }
        var stamped = try await makePostRequest(path: "/sync/courses/upload", body: request)
        stamped.setValue("2", forHTTPHeaderField: "X-TigerSync-Protocol")
        do {
            _ = try await execute(stamped)
        } catch PushAPIError.httpStatus(409, let body) where body.contains("clock_ahead") {
            var unstamped = request
            unstamped.adds = nil
            try await uploadCourses(unstamped)
        }
    }

    func deleteAllCourses(semester: String? = nil) async throws {
        var components = URLComponents()
        components.path = "/sync/courses"
        if let semester {
            components.queryItems = [URLQueryItem(name: "semester", value: semester)]
        }
        try await delete(path: components.string ?? "/sync/courses")
    }

    /// With `madeAt`, the backend applies the delete only when that time is later than the
    /// course's last add, hide and reset; without it, or once it refuses that time as ahead of its
    /// clock (409 `clock_ahead`), the delete counts from when it arrives.
    func deleteCourse(courseKey: String, madeAt stamp: Date? = nil) async throws {
        let path = "/sync/courses/\(courseKey)"
        guard let stamp else { return try await delete(path: path) }
        do {
            try await delete(path: "\(path)?hlc=\(PushAPI.clock(of: stamp))")
        } catch PushAPIError.httpStatus(409, let body) where body.contains("clock_ahead") {
            try await delete(path: path)
        }
    }

    func uploadAssignments(_ request: PushAPI.AssignmentUploadRequest) async throws {
        _ = try await postExpectingNoBody(path: "/sync/assignments/upload", body: request)
    }

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

    func ping() async throws {
        let url = baseURLProvider().appendingPathComponent("ping")
        _ = try await execute(URLRequest(url: url))
    }

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

    private func delete(path: String, at baseURL: URL? = nil) async throws {
        let baseURL = baseURL ?? baseURLProvider()
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
    case syncRevisionExpired
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
