import Foundation

extension Array where Element == SDAssignment {
    func unfinished(for courseNo: String) -> [SDAssignment] {
        filter { $0.courseNo == courseNo && !$0.isCompleted && !$0.isArchived && !$0.isLocallyCompleted }
    }

    func hasUnfinished(for courseNo: String) -> Bool {
        contains { $0.courseNo == courseNo && !$0.isCompleted && !$0.isArchived && !$0.isLocallyCompleted }
    }

    func upcomingSorted() -> [SDAssignment] {
        filter { !$0.isCompleted && !$0.isArchived && !$0.isLocallyCompleted }
            .sorted { $0.dueDate < $1.dueDate }
    }

    func ignoredSorted() -> [SDAssignment] {
        filter { $0.isArchived }
            .sorted { $0.dueDate < $1.dueDate }
    }

    func hasIgnored() -> Bool {
        contains { $0.isArchived }
    }

    func allCandidates() -> [SDAssignment] {
        filter { !$0.isArchived || $0.isCompleted }
    }

    func partitionedByDueDate(now: Date) -> [SDAssignment] {
        let future = filter { $0.dueDate >= now }.sorted { $0.dueDate < $1.dueDate }
        let past = filter { $0.dueDate < now }.sorted { $0.dueDate > $1.dueDate }
        return future + past
    }
}
