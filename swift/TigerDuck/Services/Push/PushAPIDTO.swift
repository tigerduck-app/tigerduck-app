import Foundation

enum PushAPI {

    nonisolated struct DeviceRegisterRequest: Encodable, Sendable {
        let client_device_id: String
        let platform: String
        let device_class: String?
        let app_version: String?
        let os_version: String?
        let device_model: String?
        let locale: String?
        let push_token: PushTokenIn?
        let cloud_sync_enabled: Bool?
        let bulletin_push_enabled: Bool?
        let server_push_enabled: Bool?
    }

    nonisolated struct PushTokenIn: Encodable, Sendable {
        let provider: String
        let token_kind: String
        let token_value: String
        let bundle_id: String
        /// "development" or "production" — must match the build configuration.
        let environment: String
        let scope_key: String
    }

    struct AnonymousDeviceRequest: Encodable, Sendable {
        let device_id: String
        let platform: String
        let device_class: String
        let push_token: String?
        let bundle_id: String
        let server_push_enabled: Bool?
    }

    struct DeviceRegisterResponse: Decodable, Sendable {
        let device_id: String
        let push_token_id: Int?
    }

    struct HolidayOverrideRequest: Encodable, Sendable {
        let notify: Bool
    }

    nonisolated struct DevicePreferencesRequest: Codable, Sendable {
        var serverPushEnabled: Bool?
        var syncCourses: Bool?
        var syncCourseColors: Bool?
        var syncCourseNames: Bool?
        var syncAssignments: Bool?
        var syncAssignmentReminders: Bool?
        var syncLiveActivity: Bool?
        var cloudSyncEnabled: Bool?
        var bulletinPushEnabled: Bool?

        enum CodingKeys: String, CodingKey {
            case serverPushEnabled = "server_push_enabled"
            case syncCourses = "sync_courses"
            case syncCourseColors = "sync_course_colors"
            case syncCourseNames = "sync_course_names"
            case syncAssignments = "sync_assignments"
            case syncAssignmentReminders = "sync_assignment_reminders"
            case syncLiveActivity = "sync_live_activity"
            case cloudSyncEnabled = "cloud_sync_enabled"
            case bulletinPushEnabled = "bulletin_push_enabled"
        }
    }

    nonisolated struct DevicePreferencesResponse: Codable, Sendable {
        let deviceId: String
        let serverPushEnabled: Bool
        let syncCourses: Bool
        let syncCourseColors: Bool
        let syncCourseNames: Bool
        let syncAssignments: Bool
        let syncAssignmentReminders: Bool?
        let syncLiveActivity: Bool?
        let cloudSyncEnabled: Bool
        let bulletinPushEnabled: Bool?

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case serverPushEnabled = "server_push_enabled"
            case syncCourses = "sync_courses"
            case syncCourseColors = "sync_course_colors"
            case syncCourseNames = "sync_course_names"
            case syncAssignments = "sync_assignments"
            case syncAssignmentReminders = "sync_assignment_reminders"
            case syncLiveActivity = "sync_live_activity"
            case cloudSyncEnabled = "cloud_sync_enabled"
            case bulletinPushEnabled = "bulletin_push_enabled"
        }
    }

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

    #if os(iOS)
    struct LiveActivityRegisterV3Request: Encodable, Sendable {
        let activity_id: String
        let source_id: String
        let update_token_hex: String
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

    struct AssignmentOverrideRequest: Encodable, Sendable {
        let localStatus: String

        enum CodingKeys: String, CodingKey {
            case localStatus = "local_status"
        }
    }

    struct CourseOverrideRequest: Encodable, Sendable {
        let colorHex: String?
        let customName: String?
        let locale: String?
        var ignoreAssignments: Bool? = nil
        var moodleCourseId: Int? = nil

        enum CodingKeys: String, CodingKey {
            case colorHex = "color_hex"
            case customName = "custom_name"
            case locale
            case ignoreAssignments = "ignore_assignments"
            case moodleCourseId = "moodle_course_id"
        }
    }

    struct CourseOverrideResponse: Decodable, Sendable {
        let id: Int
        let colorHex: String?
        let customNames: [String: String]
        let ignoreAssignments: Bool?
        let updatedAt: String

        enum CodingKeys: String, CodingKey {
            case id
            case colorHex = "color_hex"
            case customNames = "custom_names"
            case ignoreAssignments = "ignore_assignments"
            case updatedAt = "updated_at"
        }
    }

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
        /// Sent with `X-TigerSync-Protocol: 2`, under which the backend reads them in place of
        /// `forceKeys` and files the rest of `courses` as the school's roster.
        var adds: [CourseAdd]?
        /// The terms whose listed courses are the school's whole roster; the backend drops the
        /// school courses of those terms that the upload leaves out.
        var rosterTerms: [String]?

        enum CodingKeys: String, CodingKey {
            case courses
            case courseOverrides = "course_overrides"
            case forceKeys = "force_keys"
            case adds
            case rosterTerms = "roster_terms"
        }
    }

    /// An add the backend applies only when `hlc` is later than the course's last add, hide and
    /// reset (`server/sync/membership.py` in tigerduck-backend).
    struct CourseAdd: Encodable, Sendable {
        let courseKey: String
        let hlc: Int64

        enum CodingKeys: String, CodingKey {
            case courseKey = "course_key"
            case hlc
        }
    }

    /// The backend's TigerSync clock value for a time: whole microseconds since the Unix epoch.
    nonisolated static func clock(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded(.down))
    }

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

    nonisolated struct SyncChangesPage: Decodable, Equatable, Sendable {
        let currentRevision: Int
        let returnedUntilRevision: Int
        let hasMore: Bool
        let changes: [Change]

        nonisolated struct Change: Decodable, Equatable, Sendable {
            let revision: Int
            let entityType: String

            enum CodingKeys: String, CodingKey {
                case revision
                case entityType = "entity_type"
            }
        }

        enum CodingKeys: String, CodingKey {
            case currentRevision = "current_revision"
            case returnedUntilRevision = "returned_until_revision"
            case hasMore = "has_more"
            case changes
        }
    }
}
