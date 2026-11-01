import Foundation
import os

final class PushAPIClient: Sendable {
    let backend: BackendClient
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.API")

    init(backend: BackendClient) {
        self.backend = backend
    }

    convenience init(
        baseURLProvider: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        session: URLSession? = nil,
        auth: BackendAuth = .none,
        versionGate: APIVersionGate? = nil
    ) {
        self.init(backend: BackendClient(
            baseURL: baseURLProvider, session: session ?? BackendClient.session, auth: auth, versionGate: versionGate
        ))
    }

    func registerDevice(
        _ request: PushAPI.DeviceRegisterRequest, for signIn: SignIn
    ) async throws -> PushAPI.DeviceRegisterResponse {
        try await backend.send(
            BackendRequest("POST", "devices", "register").json(request).sent(for: signIn), as: PushAPI.DeviceRegisterResponse.self
        )
    }

    func registerAnonymousDevice(_ request: PushAPI.AnonymousDeviceRequest) async throws {
        var anonymous = try BackendRequest("POST", "devices", "anonymous").json(request)
        anonymous.authenticated = false
        _ = try await backend.send(anonymous)
    }

    func unregisterDevice(deviceId: String, at baseURL: URL? = nil) async throws {
        var request = BackendRequest("DELETE", segments: ["devices", deviceId])
        request.baseURL = baseURL
        _ = try await backend.send(request)
    }

    func putHolidayOverride(
        holidayID: Int, notify: Bool, madeAt stamp: Date, for signIn: SignIn
    ) async throws -> PushAPI.HolidayOverrideResponse {
        try await backend.sendStamped(at: stamp) { hlc in
            try BackendRequest("PUT", segments: ["sync", "holiday-overrides", String(holidayID)])
                .json(PushAPI.HolidayOverrideRequest(notify: notify, hlc: hlc)).sent(for: signIn)
        }.decoded(PushAPI.HolidayOverrideResponse.self)
    }

    func hasAuthSession() async -> Bool {
        await backend.hasAuthSession()
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
        bulletinPushEnabled: Bool? = nil,
        for signIn: SignIn
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
        let request = try BackendRequest("PATCH", segments: ["devices", deviceId, "preferences"]).json(body).sent(for: signIn)
        return try await backend.send(request, as: PushAPI.DevicePreferencesResponse.self)
    }

    func syncSchedule(_ request: PushAPI.ScheduleSyncRequest, for signIn: SignIn) async throws -> PushAPI.ScheduleSyncResponse {
        try await backend.send(
            BackendRequest("POST", "schedule", "sync").json(request).sent(for: signIn), as: PushAPI.ScheduleSyncResponse.self
        )
    }

    #if os(iOS)
    func registerLiveActivityToken(
        _ request: PushAPI.LiveActivityRegisterV3Request, for signIn: SignIn
    ) async throws -> PushAPI.LiveActivityTokenRegisterResponse {
        try await backend.send(
            BackendRequest("POST", "live-activities", "register").json(request).sent(for: signIn),
            as: PushAPI.LiveActivityTokenRegisterResponse.self
        )
    }
    #endif

    func updateCredentials(
        moodleToken: String,
        moodlePrivateToken: String?,
        for signIn: SignIn
    ) async throws -> PushAPI.UpdateCredentialsResponse {
        let body = PushAPI.UpdateCredentialsRequest(moodleToken: moodleToken, moodlePrivateToken: moodlePrivateToken)
        return try await backend.send(
            BackendRequest("PATCH", "auth", "credentials").json(body).sent(for: signIn),
            as: PushAPI.UpdateCredentialsResponse.self
        )
    }

    func patchAssignmentOverride(
        moodleAssignmentId: String,
        localStatus: String,
        madeAt stamp: Date,
        for signIn: SignIn
    ) async throws -> PushAPI.AssignmentOverrideResponse {
        try await backend.sendStamped(at: stamp) { hlc in
            try BackendRequest("PATCH", segments: ["sync", "assignments", moodleAssignmentId, "override"])
                .json(PushAPI.AssignmentOverrideRequest(localStatus: localStatus, hlc: hlc)).sent(for: signIn)
        }.decoded(PushAPI.AssignmentOverrideResponse.self)
    }

    /// `courseKey` is `client:{semester}:{course_no}`.
    func patchCourseOverride(
        courseKey: String,
        colorHex: String? = nil,
        customName: String? = nil,
        locale: String? = nil,
        ignoreAssignments: Bool? = nil,
        moodleCourseId: Int? = nil,
        madeAt stamp: Date,
        for signIn: SignIn
    ) async throws -> PushAPI.CourseOverrideResponse {
        try await backend.sendStamped(at: stamp) { hlc in
            try BackendRequest("PATCH", segments: ["sync", "courses", courseKey, "override"]).json(PushAPI.CourseOverrideRequest(
                colorHex: colorHex, customName: customName, locale: locale,
                ignoreAssignments: ignoreAssignments, moodleCourseId: moodleCourseId, hlc: hlc
            )).sent(for: signIn)
        }.decoded(PushAPI.CourseOverrideResponse.self)
    }

    func uploadCourses(_ request: PushAPI.CourseUploadRequest, addedAt stamp: Date? = nil, for signIn: SignIn) async throws {
        guard let stamp, let adds = request.adds, !adds.isEmpty else {
            _ = try await backend.send(BackendRequest("POST", "sync", "courses", "upload").json(request).sent(for: signIn))
            return
        }
        _ = try await backend.sendStamped(at: stamp) { hlc in
            var stamped = request
            stamped.adds = adds.map { PushAPI.CourseAdd(courseKey: $0.courseKey, hlc: hlc) }
            return try BackendRequest("POST", "sync", "courses", "upload").json(stamped).sent(for: signIn)
        }
    }

    func deleteAllCourses(semester: String? = nil, madeAt stamp: Date, for signIn: SignIn) async throws {
        _ = try await backend.sendStamped(at: stamp) { hlc in
            var request = BackendRequest("DELETE", "sync", "courses").sent(for: signIn)
            request.query = (semester.map { [URLQueryItem(name: "semester", value: $0)] } ?? [])
                + [URLQueryItem(name: "hlc", value: String(hlc))]
            return request
        }
    }

    func deleteCourse(courseKey: String, madeAt stamp: Date, for signIn: SignIn) async throws {
        _ = try await backend.sendStamped(at: stamp) { hlc in
            var request = BackendRequest("DELETE", segments: ["sync", "courses", courseKey]).sent(for: signIn)
            request.query = [URLQueryItem(name: "hlc", value: String(hlc))]
            return request
        }
    }

    func uploadAssignments(_ request: PushAPI.AssignmentUploadRequest, for signIn: SignIn) async throws {
        _ = try await backend.send(BackendRequest("POST", "sync", "assignments", "upload").json(request).sent(for: signIn))
    }

    func fetchRevision(for signIn: SignIn) async throws -> Int {
        let request = BackendRequest("GET", "sync", "revision").sent(for: signIn)
        guard let revision = try await backend.send(request).jsonObject()["revision"] as? Int else {
            throw PushAPIError.decodingFailed(NSError(
                domain: "PushAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing 'revision' in response"]
            ))
        }
        return revision
    }

    func fetchFullSync(for signIn: SignIn) async throws -> [String: Any] {
        try await backend.send(BackendRequest("GET", "sync", "full").sent(for: signIn)).jsonObject()
    }

    /// The changes after `sinceRevision`. Once the backend has compacted them it answers 409
    /// `sync_revision_expired`, thrown as `syncRevisionExpired`.
    func fetchChanges(sinceRevision: Int, for signIn: SignIn) async throws -> PushAPI.SyncChangesPage {
        var request = BackendRequest("GET", "sync").sent(for: signIn)
        request.query = [URLQueryItem(name: "since_revision", value: String(sinceRevision))]
        do {
            return try await backend.send(request, as: PushAPI.SyncChangesPage.self)
        } catch PushAPIError.decodingFailed(let error) {
            logger.error("Push.API decode failed path=/sync error=\(String(describing: error), privacy: .private)")
            throw PushAPIError.decodingFailed(error)
        }
    }
}

enum PushAPIError: Error, LocalizedError {
    case encodingFailed(Error)
    case decodingFailed(Error)
    case invalidResponse
    case httpStatus(Int, body: String, sent: SentToken? = nil)
    case syncRevisionExpired
    case clockAhead(serverClock: Int64?)
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .encodingFailed(let error): return "Push encode failed: \(error.localizedDescription)"
        case .decodingFailed(let error): return "Push decode failed: \(error.localizedDescription)"
        case .invalidResponse: return "Push server returned a non-HTTP response."
        case .httpStatus(let code, let body, _): return "Push server returned HTTP \(code): \(body)"
        case .syncRevisionExpired: return "Push server has compacted the changes asked for."
        case .clockAhead: return "Push server refused a time ahead of its clock."
        case .notSignedIn: return String(localized: "common_auto_sign_in_failed")
        }
    }

    var code: String? {
        guard case .httpStatus(_, let body, _) = self else { return nil }
        return BackendClient.errorCode(in: Data(body.utf8))
    }

    nonisolated struct SentToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let value: String
        var description: String { "***" }
        var debugDescription: String { "***" }
    }
}
