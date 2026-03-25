import Foundation

extension Array where Element == SDAssignment {
    func unfinished(for courseNo: String) -> [SDAssignment] {
        filter { $0.courseNo == courseNo && !$0.isCompleted }
    }

    func hasUnfinished(for courseNo: String) -> Bool {
        contains { $0.courseNo == courseNo && !$0.isCompleted }
    }

    /// Returns incomplete assignments sorted by due date ascending.
    func upcomingSorted() -> [SDAssignment] {
        filter { !$0.isCompleted }.sorted { $0.dueDate < $1.dueDate }
    }
}
