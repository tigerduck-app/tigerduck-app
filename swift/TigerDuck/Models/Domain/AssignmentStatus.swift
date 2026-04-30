import SwiftUI

/// Presentation status for a Moodle assignment, derived from submission
/// state, due date, and cutoff date. One enum per row-visible condition
/// so the view layer just switches on this value instead of re-deriving
/// rules from dates.
enum AssignmentStatus: Sendable, Equatable {
    /// Not submitted, before the due date.
    case pending
    /// Submitted on or before the due date.
    case submitted
    /// Submitted after the due date (Moodle still recorded it).
    case submittedLate
    /// Past the due date, still accepting late submissions.
    case overdueAcceptable
    /// Past the cutoff — Moodle rejects further submissions.
    case overdueRejected
    /// Locally ignored by the user (swipe-left). Moodle still sees it as unsubmitted.
    case archived
    /// Locally marked complete by the user (swipe-right). Moodle still sees it as unsubmitted.
    case locallyCompleted
}

extension AssignmentStatus {
    /// Short human label shown in the row. `nil` for `.pending` because
    /// pending rows display only the relative/absolute due time.
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

    /// Tint applied to the badge label and the due-time text.
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

    /// Whether to render the badge/time with a heavier weight. Reserved
    /// for `.overdueRejected` to signal "you can no longer submit".
    var usesEmphasis: Bool {
        self == .overdueRejected
    }

    /// Whether the row should show swipe actions (ignore / mark complete).
    /// Any not-yet-submitted row can be acted upon locally; submitted rows are
    /// Moodle-authoritative and remain non-swipeable.
    var isSwipeActionEligible: Bool {
        self == .pending || self == .overdueAcceptable || self == .overdueRejected
    }
}
