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
        /// Form factor, for operator targeting. Redundant with `platform` on
        /// Apple, where ios / ipados / macos already separate the three — but
        /// Android reports one value for phones and tablets, so targeting
        /// filters on this column and falls back to `platform` only for rows
        /// that predate it. Sending it keeps Apple devices off that fallback.
        let device_class: String?
        let app_version: String?
        let os_version: String?
        /// BCP-47 tag for the language the app is actually displaying, so the
        /// server can compose push copy in it. Sent unconditionally — it is a
        /// device fact, not a preference.
        let locale: String?
        let push_token: PushTokenIn?
        let cloud_sync_enabled: Bool?
        /// Carried on every register call, not just when the bulletin
        /// page's toggle changes, so a migrated value or a PATCH the
        /// server missed self-heals the moment the device next registers.
        let bulletin_push_enabled: Bool?
        /// Self-heals the operator-push opt-out the same way, alongside
        /// it. Today only the anonymous announce (`AnonymousDeviceRequest`)
        /// carries the equivalent value; the signed-in row otherwise only
        /// changes when the TigerSync toggle's own PATCH succeeds.
        let server_push_enabled: Bool?
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

    /// Device-only registration, for an app with no account on it.
    ///
    /// Deliberately carries no student id, no account and no preferences —
    /// just enough for an operator to see that a device is running the app
    /// and send it a custom push. `platform` is the flat apple/android value
    /// the legacy `device_registrations` table uses, not the precise
    /// ios/ipados/macos of `DeviceRegisterRequest`; the iPhone/iPad/Mac
    /// distinction rides in `device_class`.
    struct AnonymousDeviceRequest: Encodable, Sendable {
        let device_id: String
        let platform: String
        let device_class: String
        let push_token: String?
        let bundle_id: String
        /// The signed-out half of the server-push opt-out.
        ///
        /// `PATCH /devices/{id}/preferences` needs a session and writes
        /// `user_devices`, but operator targeting resolves signed-out
        /// devices from `device_registrations` — so without this the
        /// toggle had no way to reach the row that actually decides, and
        /// a device that opted out kept receiving custom push.
        let server_push_enabled: Bool?
    }

    struct DeviceRegisterResponse: Decodable, Sendable {
        let device_id: String
        let push_token_id: Int?
    }

    // MARK: - Device unregister (v3 uses DELETE /devices/{id}, no request body needed)

    /// "Keep reminding me about classes on this holiday."
    struct HolidayOverrideRequest: Encodable, Sendable {
        let notify: Bool
    }

    // MARK: - Device preferences (unchanged shape)

    /// `nonisolated`: this target defaults unannotated types to `@MainActor`
    /// (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), but a plain request
    /// DTO has no actor affinity and must be encodable from any isolation
    /// domain — including `PushAPIClient`, a plain `Sendable` class, and
    /// non-`@MainActor` test functions. Without this the compiler-
    /// synthesized `Encodable` conformance is main-actor-isolated, which is
    /// only a warning in today's Swift 5 mode but a hard error in Swift 6
    /// (same reasoning as `NotificationSettingsDocument`'s own `nonisolated`).
    nonisolated struct DevicePreferencesRequest: Codable, Sendable {
        var serverPushEnabled: Bool?
        var syncCourses: Bool?
        var syncCourseColors: Bool?
        var syncCourseNames: Bool?
        var syncAssignments: Bool?
        /// Device-level gate for whether the server should push
        /// assignment-due reminders to this device, now that reminder
        /// scheduling has moved server-side (v2.1.0). Distinct from the
        /// notification settings document's `assignments` section, which
        /// holds the user's reminder preferences themselves — `enabled`,
        /// the account-wide on/off switch, and `reminder_offsets_*`, which
        /// offsets. This is whether this one device takes part.
        var syncAssignmentReminders: Bool?
        /// Same shape as `syncAssignmentReminders`, for Live Activity.
        var syncLiveActivity: Bool?
        var cloudSyncEnabled: Bool?
        /// Per-device bulletin opt-out (spec §6 item 5) — distinct from
        /// `serverPushEnabled` above, which covers operator-issued pushes
        /// only and never gates bulletin delivery.
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

    /// `nonisolated` for the same reason as `DevicePreferencesRequest`
    /// above: a plain response DTO must be decodable from any isolation
    /// domain, including non-`@MainActor` test functions.
    nonisolated struct DevicePreferencesResponse: Codable, Sendable {
        let deviceId: String
        let serverPushEnabled: Bool
        let syncCourses: Bool
        let syncCourseColors: Bool
        let syncCourseNames: Bool
        let syncAssignments: Bool
        /// Optional although the backend always sends them (non-null with a
        /// `server_default`, migration `07b22743e0f1`): nothing reads them,
        /// and requiring them would fail the decode of every preferences
        /// PATCH answered by a backend without the columns — a rollback, or
        /// a self-hosted server — reporting failure for a change that was
        /// applied.
        let syncAssignmentReminders: Bool?
        let syncLiveActivity: Bool?
        let cloudSyncEnabled: Bool
        /// Optional for the same reason as `syncAssignmentReminders` above:
        /// the backend always sends it (NOT NULL, `server_default true`),
        /// but requiring it would fail the decode of every preferences
        /// PATCH answered by a backend without the column.
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
