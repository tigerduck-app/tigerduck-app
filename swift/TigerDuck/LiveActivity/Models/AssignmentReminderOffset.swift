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
        case .hr48: return "48 小時前"
        case .hr24: return "24 小時前"
        case .hr16: return "16 小時前"
        case .hr8:  return "8 小時前"
        case .hr4:  return "4 小時前"
        case .hr2:  return "2 小時前"
        case .hr1:  return "1 小時前"
        case .min30: return "30 分鐘前"
        case .min15: return "15 分鐘前"
        case .min10: return "10 分鐘前"
        case .min5:  return "5 分鐘前"
        }
    }

    /// Copy template used in the local notification body. Kept inline for
    /// the first cut; can be extracted to Localizable.xcstrings later.
    func notificationBody(assignmentTitle: String, courseName: String) -> String {
        switch self {
        case .hr48:
            return "\(courseName)「\(assignmentTitle)」還有一段時間就到期"
        case .hr24:
            return "還剩下 24 小時！\(courseName)「\(assignmentTitle)」"
        case .hr16:
            return "準備繳交作業！\(courseName)「\(assignmentTitle)」"
        case .hr8, .hr4, .hr2, .hr1:
            return "還來得及補救！\(courseName)「\(assignmentTitle)」"
        case .min30:
            return "快來不及了！\(courseName)「\(assignmentTitle)」"
        case .min15, .min10:
            return "拜託做一下作業... \(courseName)「\(assignmentTitle)」"
        case .min5:
            return "涼了... \(courseName)「\(assignmentTitle)」"
        }
    }
}
