import Foundation

/// Value type handed to the scheduler to emit a single local notification.
/// Rendered from an assignment + offset pair before scheduling so the
/// scheduler does not know about SwiftData models.
struct ReminderPayload: Equatable, Sendable {
    /// Stable id: "\(assignmentId)_\(offset.rawValue)". Used to cancel / replace.
    let id: String
    let fireDate: Date
    let title: String
    let body: String
    let assignmentId: String
    let offset: AssignmentReminderOffset
}
