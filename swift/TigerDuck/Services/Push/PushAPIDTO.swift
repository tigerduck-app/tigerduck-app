import Foundation

/// Request/response DTOs for the TigerDuck push server.
///
/// These mirror `backend/server/schemas.py`. Keep both sides in sync when
/// evolving the API contract.
enum PushAPI {
    struct DeviceRegisterRequest: Codable, Sendable {
        let userId: String
        let deviceId: String
        let ptsTokenHex: String
        let deviceTokenHex: String?
        let bundleId: String
        let attrsType: String
        let apnsEnv: String

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case deviceId = "device_id"
            case ptsTokenHex = "pts_token_hex"
            case deviceTokenHex = "device_token_hex"
            case bundleId = "bundle_id"
            case attrsType = "attrs_type"
            case apnsEnv = "apns_env"
        }
    }

    struct DeviceRegisterResponse: Codable, Sendable {
        let deviceId: String
        let userId: String
        let registeredAt: Date

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case userId = "user_id"
            case registeredAt = "registered_at"
        }
    }

    struct DeviceUnregisterRequest: Codable, Sendable {
        let deviceId: String

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
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

    struct ScheduleSyncRequest: Codable, Sendable {
        let deviceId: String
        let events: [ScheduleEvent]

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case events
        }
    }

    struct ScheduleSyncResponse: Codable, Sendable {
        let deviceId: String
        let scheduled: Int
        let cancelled: Int
        let totalPending: Int

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case scheduled
            case cancelled
            case totalPending = "total_pending"
        }
    }
}
