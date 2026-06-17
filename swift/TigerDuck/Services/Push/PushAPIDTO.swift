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
        let device_name: String?
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
        let serverPushEnabled: Bool

        enum CodingKeys: String, CodingKey {
            case serverPushEnabled = "server_push_enabled"
        }
    }

    struct DevicePreferencesResponse: Codable, Sendable {
        let deviceId: String
        let serverPushEnabled: Bool

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case serverPushEnabled = "server_push_enabled"
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
        let scheduled: Int
        let cancelled: Int
        let totalPending: Int

        enum CodingKeys: String, CodingKey {
            case scheduled
            case cancelled
            case totalPending = "total_pending"
        }
    }

    // MARK: - Live Activity token registration (v3)

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
        let activityId: String
        let registeredAt: Date

        enum CodingKeys: String, CodingKey {
            case activityId = "activity_id"
            case registeredAt = "registered_at"
        }
    }
}
