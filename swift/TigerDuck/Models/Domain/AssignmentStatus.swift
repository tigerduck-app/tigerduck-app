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
}

extension AssignmentStatus {
    /// Short human label shown in the row. `nil` for `.pending` because
    /// pending rows display only the relative/absolute due time.
    var badgeLabel: String? {
        switch self {
        case .pending: return nil
        case .submitted: return "已繳交"
        case .submittedLate: return "已遲交"
        case .overdueAcceptable: return "逾期"
        case .overdueRejected: return "逾期拒收"
        }
    }

    /// Tint applied to the badge label and the due-time text.
    var tint: Color {
        switch self {
        case .pending: return .secondary
        case .submitted: return .green
        case .submittedLate: return .orange
        case .overdueAcceptable, .overdueRejected: return .badgeRed
        }
    }

    /// Whether to render the badge/time with a heavier weight. Reserved
    /// for `.overdueRejected` to signal "you can no longer submit".
    var usesEmphasis: Bool {
        self == .overdueRejected
    }
}
