import Foundation

/// Every section and every field must stay Optional: three clients write it
/// unvalidated, and a required key one has not written fails every decode.
/// See docs/decisions/0002-notification-settings-json-merge.md.
nonisolated struct NotificationSettingsDocument: Codable, Equatable, Sendable {
    nonisolated struct Assignments: Codable, Equatable, Sendable {
        var enabled: Bool?
        /// Whole-hour reminder offsets as integers, descending, for readers
        /// that predate `reminder_offsets_minutes` (an older Android build).
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
