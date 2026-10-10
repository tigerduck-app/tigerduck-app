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
        /// The complete offset set in whole minutes, sub-hour offsets included,
        /// shaped like `courses.reminder_offsets_minutes`, which both platforms
        /// already parse. Readers that know this key prefer it over
        /// `reminder_offsets_hours`, the backend (`server/push/reminders.py`) too.
        /// `nil` (an older or foreign writer, or not a JSON array) means the
        /// document cannot describe sub-hour offsets; see
        /// `NotificationSettingsSync.resolveOffsets`. Empty means none are selected,
        /// even when every element was unreadable, as the backend also reads it.
        var reminderOffsetsMinutes: [Int]?

        enum CodingKeys: String, CodingKey {
            case enabled
            case reminderOffsetsHours = "reminder_offsets_hours"
            case reminderOffsetsMinutes = "reminder_offsets_minutes"
        }
    }

    /// Course-start reminders. Owned by a different feature — this app only
    /// ever passes the section through untouched (and, since the write path
    /// merges at the JSON level, does not even need to decode it to do so).
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

// The two sections this app adopts decode field by field: a field of the wrong
// type reads as absent, so `NotificationSettingsSync.apply` keeps its local value
// and still adopts the fields beside it. In extensions so the memberwise initializers stay.
nonisolated extension NotificationSettingsDocument.Assignments {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try? container.decodeIfPresent(Bool.self, forKey: .enabled)
        reminderOffsetsHours = wholeNumberList(in: container, forKey: .reminderOffsetsHours)
        reminderOffsetsMinutes = wholeNumberList(in: container, forKey: .reminderOffsetsMinutes)
    }
}

/// One element of an offset array: the whole number it holds, or nothing.
///
/// Never throws, which is the whole point — `[WholeNumberElement]` decodes
/// whatever a JSON array contains, so a bad element cannot fail the array
/// around it.
private nonisolated struct WholeNumberElement: Decodable {
    let value: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // A string, `null`, a nested array or object, a fraction, or a
        // number too large for `Int` all land here as `nil`.
        value = try? container.decode(Int.self)
    }
}

/// The whole numbers in the array at `key`, or `nil` when there is no JSON
/// array there (an absent key, `null`, or a value of another type).
///
/// Drops bad elements, not the array, like the backend's `_numbers`
/// (`server/push/reminders.py`) and Android's `asValidatedIntListOrNull`: all
/// three read `[30, "15"]` as the full set `[30]`, not as a reason to fall back
/// to `reminder_offsets_hours`. The backend delivers the reminders, so reading
/// it differently would give two devices on one account different reminders.
private nonisolated func wholeNumberList<Key: CodingKey>(
    in container: KeyedDecodingContainer<Key>,
    forKey key: Key
) -> [Int]? {
    // `decodeIfPresent` gives `nil` for an absent key or an explicit `null`, and
    // `try?` gives `nil` for a value that is not an array; `flatMap` collapses
    // the two levels of optionality that produces.
    let decoded = try? container.decodeIfPresent([WholeNumberElement].self, forKey: key)
    guard let elements = decoded.flatMap({ $0 }) else { return nil }
    return elements.compactMap(\.value)
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
