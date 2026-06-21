import Foundation

/// Request/response DTOs for the TigerDuck push server (v3).
///
/// These mirror `backend/server/schemas.py`. Keep both sides in sync when
/// evolving the API contract.
enum PushAPI {
    // MARK: - Device registration (v3)

    struct DeviceRegisterRequest: Encodable, Sendable {
        let client_device_id: String
        let platform: String
        let app_version: String?
        let os_version: String?
        let push_token: PushTokenIn?
    }

    struct PushTokenIn: Encodable, Sendable {
        /// Always "apns".
        let provider: String
        /// "standard" for the APNs device token, "push_to_start" for the PTS token.
        let token_kind: String
        let token_value: String
        let bundle_id: String
        /// "development" or "production" — must match the build configuration.
        let environment: String
        /// Identifies the activity-attributes type for PTS; empty string for
        /// standard tokens.
        let scope_key: String
    }

    struct DeviceRegisterResponse: Decodable, Sendable {
        let device_id: String
        let push_token_id: Int?
    }

    // MARK: - Device unregister (v3 uses DELETE /devices/{id}, no request body needed)

    // MARK: - Device preferences (unchanged shape)

    struct DevicePreferencesRequest: Codable, Sendable {
        var serverPushEnabled: Bool?
        var syncCourses: Bool?
        var syncCourseColors: Bool?
        var syncCourseNames: Bool?
        var syncAssignments: Bool?
        var cloudSyncEnabled: Bool?

        enum CodingKeys: String, CodingKey {
            case serverPushEnabled = "server_push_enabled"
            case syncCourses = "sync_courses"
            case syncCourseColors = "sync_course_colors"
            case syncCourseNames = "sync_course_names"
            case syncAssignments = "sync_assignments"
            case cloudSyncEnabled = "cloud_sync_enabled"
        }
    }

    struct DevicePreferencesResponse: Codable, Sendable {
        let deviceId: String
        let serverPushEnabled: Bool
        let syncCourses: Bool
        let syncCourseColors: Bool
        let syncCourseNames: Bool
        let syncAssignments: Bool
        let cloudSyncEnabled: Bool

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case serverPushEnabled = "server_push_enabled"
            case syncCourses = "sync_courses"
            case syncCourseColors = "sync_course_colors"
            case syncCourseNames = "sync_course_names"
            case syncAssignments = "sync_assignments"
            case cloudSyncEnabled = "cloud_sync_enabled"
        }
    }

    // MARK: - Schedule sync (v3: no device_id in body; inferred from JWT)

    enum ScenarioKind: String, Codable, Sendable {
        case classPreparing
        case inClass
        case assignmentUrgent
    }

    struct ScheduleEvent: Codable, Sendable {
        let sourceId: String
        let scenario: ScenarioKind
        let fireAt: Date
        let snapshot: LiveActivitySnapshot

        enum CodingKeys: String, CodingKey {
            case sourceId = "source_id"
            case scenario
            case fireAt = "fire_at"
            case snapshot
        }
    }

    struct ScheduleSyncRequest: Encodable, Sendable {
        let events: [ScheduleEvent]
    }

    struct ScheduleSyncResponse: Codable, Sendable {
        let pending: Int
        let replaced: Int
    }

    // MARK: - Live Activity token registration (v3, iOS only)

    #if os(iOS)
    struct LiveActivityRegisterV3Request: Encodable, Sendable {
        let activity_id: String
        let source_id: String
        let update_token_hex: String
        /// ISO 8601 string.
        let countdown_target: String?
        let snapshot: LiveActivitySnapshot
        let bundle_id: String
        let environment: String?
    }

    struct LiveActivityTokenRegisterResponse: Codable, Sendable {
        let tokenId: Int
        let endJobId: Int?

        enum CodingKeys: String, CodingKey {
            case tokenId = "token_id"
            case endJobId = "end_job_id"
        }
    }
    #endif

    // MARK: - Credential refresh

    struct UpdateCredentialsRequest: Encodable, Sendable {
        let moodleToken: String
        let moodlePrivateToken: String?

        enum CodingKeys: String, CodingKey {
            case moodleToken = "moodle_token"
            case moodlePrivateToken = "moodle_private_token"
        }
    }

    struct UpdateCredentialsResponse: Decodable, Sendable {
        let updated: Bool
    }

    // MARK: - Override sync

    struct AssignmentOverrideRequest: Encodable, Sendable {
        let localStatus: String

        enum CodingKeys: String, CodingKey {
            case localStatus = "local_status"
        }
    }

    struct AssignmentOverrideResponse: Decodable, Sendable {
        let id: Int
        let localStatus: String
        let updatedAt: String

        enum CodingKeys: String, CodingKey {
            case id
            case localStatus = "local_status"
            case updatedAt = "updated_at"
        }
    }

    struct CourseOverrideRequest: Encodable, Sendable {
        let colorHex: String?
        let customName: String?
        let locale: String?

        enum CodingKeys: String, CodingKey {
            case colorHex = "color_hex"
            case customName = "custom_name"
            case locale
        }
    }

    struct CourseOverrideResponse: Decodable, Sendable {
        let id: Int
        let colorHex: String?
        let customNames: [String: String]
        let updatedAt: String

        enum CodingKeys: String, CodingKey {
            case id
            case colorHex = "color_hex"
            case customNames = "custom_names"
            case updatedAt = "updated_at"
        }
    }

    // MARK: - Course upload

    struct CourseUploadEntry: Encodable, Sendable {
        let semester: String
        let courseNo: String
        let courseName: String
        let courseNameEn: String?
        let moodleId: String?
        let credits: Double?
        let classroom: String?
        let instructors: [String]?
        let scheduleJson: [String: [String]]?
        let classroomMap: [String: String]?

        enum CodingKeys: String, CodingKey {
            case semester
            case courseNo = "course_no"
            case courseName = "course_name"
            case courseNameEn = "course_name_en"
            case moodleId = "moodle_id"
            case credits
            case classroom
            case instructors
            case scheduleJson = "schedule_json"
            case classroomMap = "classroom_map"
        }
    }

    struct CourseOverrideUploadEntry: Encodable, Sendable {
        let courseKey: String
        let colorHex: String?

        enum CodingKeys: String, CodingKey {
            case courseKey = "course_key"
            case colorHex = "color_hex"
        }
    }

    struct CourseUploadRequest: Encodable, Sendable {
        let courses: [CourseUploadEntry]
        var courseOverrides: [CourseOverrideUploadEntry] = []
        var forceKeys: [String] = []

        enum CodingKeys: String, CodingKey {
            case courses
            case courseOverrides = "course_overrides"
            case forceKeys = "force_keys"
        }
    }

    // MARK: - Assignment upload

    struct AssignmentUploadEntry: Encodable, Sendable {
        let moodleAssignmentId: Int
        let courseNo: String
        let courseName: String
        let title: String
        let dueAt: String?
        let moodleUrl: String?
        let isSubmitted: Bool
        let grade: String?

        enum CodingKeys: String, CodingKey {
            case moodleAssignmentId = "moodle_assignment_id"
            case courseNo = "course_no"
            case courseName = "course_name"
            case title
            case dueAt = "due_at"
            case moodleUrl = "moodle_url"
            case isSubmitted = "is_submitted"
            case grade
        }
    }

    struct AssignmentUploadRequest: Encodable, Sendable {
        let assignments: [AssignmentUploadEntry]
    }
}
