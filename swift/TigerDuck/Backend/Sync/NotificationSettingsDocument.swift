import Foundation

/// Codable mirror of the `notification` settings document, the `document`
/// payload of `GET/PUT /v3/settings/notification`. `nonisolated` because the
/// target defaults to `@MainActor`, and main-actor conformances used off it, as
/// in the `SettingsDocumentClient` actor, warn in Swift 5 and fail in Swift 6.
///
/// Every section and every field must stay Optional: three clients write it
/// unvalidated, and a required key one has not written fails every decode.
/// See docs/decisions/0002-notification-settings-json-merge.md.
nonisolated struct NotificationSettingsDocument: Codable, Equatable, Sendable {
    nonisolated struct Assignments: Codable, Equatable, Sendable {
        var enabled: Bool?
        /// Whole-hour reminder offsets as integers, descending, for readers
        /// that predate `reminder_offsets_minutes` (an older Android build).
        ///
        /// Never write a fraction here. Android types this key as `List<Int>?`
        /// (`push/NotificationSettingsDocument.kt`), and Gson throws on `0.5`,
        /// failing its decode of the whole `notification` document. The backend
        /// would accept one, but sub-hour offsets go in `reminderOffsetsMinutes`.
        var reminderOffsetsHours: [Int]?
        var reminderOffsetsMinutes: [Int]?

        enum CodingKeys: String, CodingKey {
            case enabled
            case reminderOffsetsHours = "reminder_offsets_hours"
            case reminderOffsetsMinutes = "reminder_offsets_minutes"
        }
    }

    nonisolated struct Courses: Codable, Equatable, Sendable {
        var enabled: Bool?
        var reminderOffsetsMinutes: [Int]?

        enum CodingKeys: String, CodingKey {
            case enabled
            case reminderOffsetsMinutes = "reminder_offsets_minutes"
        }
    }

    nonisolated struct LiveActivity: Codable, Equatable, Sendable {
        var showClassPreparing: Bool?
        var showInClass: Bool?
        var showAssignment: Bool?
        var classPreparingLeadSeconds: Int?
        var assignmentLeadSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case showClassPreparing = "show_class_preparing"
            case showInClass = "show_in_class"
            case showAssignment = "show_assignment"
            case classPreparingLeadSeconds = "class_preparing_lead_seconds"
            case assignmentLeadSeconds = "assignment_lead_seconds"
        }
    }

    var assignments: Assignments? = nil
    var courses: Courses? = nil
    var liveActivity: LiveActivity? = nil

    enum CodingKeys: String, CodingKey {
        case assignments
        case courses
        case liveActivity = "live_activity"
    }
}

nonisolated extension NotificationSettingsDocument.Assignments {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try? container.decodeIfPresent(Bool.self, forKey: .enabled)
        reminderOffsetsHours = wholeNumberList(in: container, forKey: .reminderOffsetsHours)
        reminderOffsetsMinutes = wholeNumberList(in: container, forKey: .reminderOffsetsMinutes)
    }
}

///
private nonisolated struct WholeNumberElement: Decodable {
    let value: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(Int.self)
    }
}

/// The whole numbers in the array at `key`, or `nil` when there is no JSON
/// array there (an absent key, `null`, or a value of another type).
/// Drops bad elements, not the array, like the backend's `_numbers`
/// (`server/push/reminders.py`) and Android's `asValidatedIntListOrNull`: all
/// three read `[30, "15"]` as the full set `[30]`, not as a reason to fall back
/// to `reminder_offsets_hours`. The backend delivers the reminders, so reading
/// it differently would give two devices on one account different reminders.
private nonisolated func wholeNumberList<Key: CodingKey>(
    in container: KeyedDecodingContainer<Key>,
    forKey key: Key
) -> [Int]? {
    let decoded = try? container.decodeIfPresent([WholeNumberElement].self, forKey: key)
    guard let elements = decoded.flatMap({ $0 }) else { return nil }
    return elements.compactMap(\.value)
}

nonisolated extension NotificationSettingsDocument.Courses {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try? container.decodeIfPresent(Bool.self, forKey: .enabled)
        reminderOffsetsMinutes = wholeNumberList(in: container, forKey: .reminderOffsetsMinutes)
    }
}

nonisolated extension NotificationSettingsDocument.LiveActivity {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showClassPreparing = try? container.decodeIfPresent(Bool.self, forKey: .showClassPreparing)
        showInClass = try? container.decodeIfPresent(Bool.self, forKey: .showInClass)
        showAssignment = try? container.decodeIfPresent(Bool.self, forKey: .showAssignment)
        classPreparingLeadSeconds = try? container.decodeIfPresent(Int.self, forKey: .classPreparingLeadSeconds)
        assignmentLeadSeconds = try? container.decodeIfPresent(Int.self, forKey: .assignmentLeadSeconds)
    }
}
