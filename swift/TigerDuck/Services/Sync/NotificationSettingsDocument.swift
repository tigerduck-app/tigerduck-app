import Foundation

/// Codable mirror of the `notification` settings-document namespace
/// (`server/sync/models/enums.py:40`; shape per spec §4.6). This is the
/// `document` payload of `GET/PUT /v3/settings/notification`, read and
/// written through `SettingsDocumentClient`.
///
/// **Every section, and every field inside every section, is Optional, and
/// must stay that way.** Three separate clients write this one document —
/// this app, Android (spec W6), and the backend's own defaults — and the
/// route accepts any object at all (`settings_docs.py`'s
/// `SettingsPut.document: dict`, no schema validation). A non-Optional
/// property makes Swift's synthesized `Decodable` require the key, so a
/// single section or field another client hasn't written yet turns every
/// read of this document into a `DecodingError.keyNotFound` — which, on the
/// push path, is an abort with nothing but a log line, repeated forever.
/// Optional turns the same document into "the server has nothing to say
/// about that field", which is what it actually means, and which every
/// reader here already knows how to handle (see
/// `NotificationSettingsSync.apply`: an absent field leaves the local value
/// alone rather than resetting it).
///
/// Concretely: the backend has accepted documents with only `assignments`
/// and `courses` since phase 4a, so accounts that synced before
/// `live_activity` shipped have no such key; the backend's own readers treat
/// `enabled` and `reminder_offsets_*` as independently optional
/// (`server/push/reminders.py:76-83`); and Android's mirror of this type
/// (`push/NotificationSettingsDocument.kt`) is Optional field for field.
/// This type matches that.
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
        var enabled: Bool?
        /// Whole-hour reminder offsets, for readers that predate
        /// `reminder_offsets_minutes` (an older Android build), so it keeps
        /// carrying exactly what it has always carried: whole hours, as
        /// integers, descending.
        ///
        /// It cannot carry a sub-hour offset. The backend would in fact
        /// cope with a fraction — it stores `list[float]` and schedules with
        /// `timedelta(hours=offset)` — but Android's mirror of this document
        /// types the same key as `List<Int>?`
        /// (`push/NotificationSettingsDocument.kt:39`), and Gson's integer
        /// adapter throws on `0.5`, failing the decode of the *whole*
        /// `notification` document. Writing a fraction here would break the
        /// other platform's read of everything in this namespace, so the
        /// sub-hour offsets go in `reminderOffsetsMinutes` instead.
        var reminderOffsetsHours: [Int]?
        /// The **complete** offset set in whole minutes, sub-hour offsets
        /// included — the lossless mirror of the local
        /// `Set<AssignmentReminderOffset>`.
        ///
        /// Added by this build. `reminder_offsets_hours` is a strict subset
        /// of it, kept for readers that predate it. A reader that knows this
        /// key prefers it (spec §4.6), the backend included
        /// (`server/push/reminders.py`); an older client that has never
        /// heard of it is unaffected.
        ///
        /// Same name and same units as `courses.reminder_offsets_minutes`,
        /// which has been in this document since phase 4a — a shape both
        /// platforms already parse, not a new idiom.
        ///
        /// `nil` (an older or foreign writer) means "this document cannot
        /// describe the sub-hour offsets"; see
        /// `NotificationSettingsSync.resolveOffsets` for what a reader does
        /// with that. Empty means the user really has no offsets selected.
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

// Forgiving, field by field, for the two sections this app adopts: a field
// of the wrong type decodes as absent instead of failing its whole section.
// Absent is what `NotificationSettingsSync.apply` already handles — the
// local value stays — so one malformed field another client wrote cannot
// stop every well-formed field beside it from being adopted. In extensions
// so the memberwise initializers stay.
nonisolated extension NotificationSettingsDocument.Assignments {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try? container.decodeIfPresent(Bool.self, forKey: .enabled)
        reminderOffsetsHours = try? container.decodeIfPresent([Int].self, forKey: .reminderOffsetsHours)
        reminderOffsetsMinutes = try? container.decodeIfPresent([Int].self, forKey: .reminderOffsetsMinutes)
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
