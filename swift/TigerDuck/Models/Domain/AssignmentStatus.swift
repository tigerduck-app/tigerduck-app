import SwiftUI

enum AssignmentStatus: Sendable, nonisolated Equatable {
    case pending
    case submitted
    case submittedLate
    case overdueAcceptable
    case overdueRejected
    case archived
    case locallyCompleted
}

extension AssignmentStatus {
    var badgeLabel: String? {
        switch self {
        case .pending: return nil
        case .submitted: return String(localized: "assignment_status_submitted")
        case .submittedLate: return String(localized: "assignment_status_submitted_late")
        case .overdueAcceptable: return String(localized: "assignment_status_overdue")
        case .overdueRejected: return String(localized: "assignment_status_overdue_rejected")
        case .archived: return String(localized: "assignment_filter_ignored")
        case .locallyCompleted: return String(localized: "assignment_mark_complete")
        }
    }

    var tint: Color {
        switch self {
        case .pending: return .secondary
        case .submitted: return .green
        case .submittedLate: return .orange
        case .overdueAcceptable, .overdueRejected: return .badgeRed
        case .archived: return .secondary
        case .locallyCompleted: return .green
        }
    }

    var usesEmphasis: Bool {
        self == .overdueRejected
    }

    var isSwipeActionEligible: Bool {
        switch self {
        case .submitted, .submittedLate: return false
        default: return true
        }
    }
}
