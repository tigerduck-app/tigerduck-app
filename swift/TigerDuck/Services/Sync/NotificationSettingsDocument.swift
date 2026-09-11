import Foundation

/// Codable mirror of the `notification` settings-document namespace
/// (`server/sync/models/enums.py:40`; shape per spec §4.6). This is the
/// `document` payload of `GET/PUT /v3/settings/notification`, read and
/// written through `SettingsDocumentClient`.
///
/// `liveActivity` is Optional and **must stay that way**: the backend has
/// accepted documents with only `assignments` and `courses` since phase
/// 4a, so any account that synced before this section shipped has a
/// stored document with no `live_activity` key at all. Swift's
/// synthesized `Decodable` conformance uses `decodeIfPresent` for an
/// Optional property, so a missing key decodes to `nil`; making this
/// non-optional would turn every pre-existing document into a
/// `DecodingError.keyNotFound` the first time this build reads it.
///
/// Explicitly `nonisolated`: this target defaults unannotated types to
/// `@MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), but a plain
/// data type mirroring a JSON document has no actor affinity and must be
/// decodable/encodable/comparable from any isolation domain — including
/// the `SettingsDocumentClient` actor and plain (non-`@MainActor`) test
/// functions. Without this, the compiler-synthesized `Codable`/`Equatable`
/// conformances would be main-actor-isolated, which is only a warning in
/// today's Swift 5 mode but a hard error in Swift 6.
nonisolated struct NotificationSettingsDocument: Codable, Equatable, Sendable {
    nonisolated struct Assignments: Codable, Equatable, Sendable {
        var enabled: Bool
        var reminderOffsetsHours: [Int]

        enum CodingKeys: String, CodingKey {
            case enabled
            case reminderOffsetsHours = "reminder_offsets_hours"
        }
    }

    nonisolated struct Courses: Codable, Equatable, Sendable {
        var enabled: Bool
        var reminderOffsetsMinutes: [Int]

        enum CodingKeys: String, CodingKey {
            case enabled
            case reminderOffsetsMinutes = "reminder_offsets_minutes"
        }
    }

    nonisolated struct LiveActivity: Codable, Equatable, Sendable {
        var showClassPreparing: Bool
        var showInClass: Bool
        var showAssignment: Bool
        var classPreparingLeadSeconds: Int
        var assignmentLeadSeconds: Int

        enum CodingKeys: String, CodingKey {
            case showClassPreparing = "show_class_preparing"
            case showInClass = "show_in_class"
            case showAssignment = "show_assignment"
            case classPreparingLeadSeconds = "class_preparing_lead_seconds"
            case assignmentLeadSeconds = "assignment_lead_seconds"
        }
    }

    var assignments: Assignments
    var courses: Courses
    var liveActivity: LiveActivity? = nil

    enum CodingKeys: String, CodingKey {
        case assignments
        case courses
        case liveActivity = "live_activity"
    }
}
