import Foundation

/// Fixed reminder points before an assignment's due date.
/// Ordered from longest lead time to shortest so UI rendering and
/// scheduling iterate in a stable direction.
nonisolated enum AssignmentReminderOffset: String, CaseIterable, Identifiable, Codable, Sendable {
    case hr48
    case hr24
    case hr16
    case hr8
    case hr4
    case hr2
    case hr1
    case min30
    case min15
    case min10
    case min5

    var id: String { rawValue }

    var timeInterval: TimeInterval {
        switch self {
        case .hr48: return 48 * 3600
        case .hr24: return 24 * 3600
        case .hr16: return 16 * 3600
        case .hr8:  return 8 * 3600
        case .hr4:  return 4 * 3600
        case .hr2:  return 2 * 3600
        case .hr1:  return 1 * 3600
        case .min30: return 30 * 60
        case .min15: return 15 * 60
        case .min10: return 10 * 60
        case .min5:  return 5 * 60
        }
    }

    /// Short user-facing label for settings list, e.g. "24 小時前".
    var label: String {
        switch self {
        case .hr48: return String(localized: "assignment_reminder_offset_48h")
        case .hr24: return String(localized: "assignment_reminder_offset_24h")
        case .hr16: return String(localized: "assignment_reminder_offset_16h")
        case .hr8:  return String(localized: "assignment_reminder_offset_8h")
        case .hr4:  return String(localized: "assignment_reminder_offset_4h")
        case .hr2:  return String(localized: "assignment_reminder_offset_2h")
        case .hr1:  return String(localized: "assignment_reminder_offset_1h")
        case .min30: return String(localized: "assignment_reminder_offset_30m")
        case .min15: return String(localized: "assignment_reminder_offset_15m")
        case .min10: return String(localized: "assignment_reminder_offset_10m")
        case .min5:  return String(localized: "assignment_reminder_offset_5m")
        }
    }

    /// Copy template used in the local notification body. Body strings live in
    /// Localization/Localizable.strings under `notification_assignment_reminder_body_*` keys.
    func notificationBody(assignmentTitle: String, courseName: String) -> String {
        let key: String
        switch self {
        case .hr48: key = "notification_assignment_reminder_body_48h"
        case .hr24: key = "notification_assignment_reminder_body_24h"
        case .hr16: key = "notification_assignment_reminder_body_16h"
        case .hr8, .hr4, .hr2, .hr1: key = "notification_assignment_reminder_body_multi_hour"
        case .min30: key = "notification_assignment_reminder_body_30m"
        case .min15, .min10: key = "notification_assignment_reminder_body_15m"
        case .min5: key = "notification_assignment_reminder_body_5m"
        }
        return String(format: String(localized: String.LocalizationValue(key)), courseName, assignmentTitle)
    }
}
