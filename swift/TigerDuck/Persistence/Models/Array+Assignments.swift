import Foundation

extension Array where Element == SDAssignment {
    func unfinished(for courseNo: String) -> [SDAssignment] {
        filter { $0.courseNo == courseNo && !$0.isCompleted && !$0.isArchived && !$0.isLocallyCompleted }
            .sortedByDueDate()
    }

    func hasUnfinished(for courseNo: String) -> Bool {
        contains { $0.courseNo == courseNo && !$0.isCompleted && !$0.isArchived && !$0.isLocallyCompleted }
    }

    func upcomingSorted() -> [SDAssignment] {
        filter { !$0.isCompleted && !$0.isArchived && !$0.isLocallyCompleted }
            .sortedByDueDate()
    }

    func ignoredSorted() -> [SDAssignment] {
        filter { $0.isArchived }
            .sortedByDueDate()
    }

    func hasIgnored() -> Bool {
        contains { $0.isArchived }
    }

    func allCandidates() -> [SDAssignment] {
        filter { !$0.isArchived || $0.isCompleted }
    }

    func ofTimetable(_ courses: [SDCourse]) -> [SDAssignment] {
        let courseNos = Set(courses.map(\.courseNo))
        return courseNos.isEmpty ? self : filter { courseNos.contains($0.courseNo) }
    }

    func sortedByDueDate(by areInOrder: (Date, Date) -> Bool = (<)) -> [SDAssignment] {
        sortedByDueDate(\.dueDate, title: \.displayTitle, by: areInOrder)
    }

    func partitionedByDueDate(now: Date) -> [SDAssignment] {
        partitionedByDueDate(\.dueDate, title: \.displayTitle, now: now)
    }
}

extension Sequence {
    /// Those with a due date in `areInOrder`'s order, then those without one by title.
    func sortedByDueDate(
        _ dueDate: (Element) -> Date?, title: (Element) -> String, by areInOrder: (Date, Date) -> Bool
    ) -> [Element] {
        sorted { lhs, rhs in
            switch (dueDate(lhs), dueDate(rhs)) {
            case let (lhsDue?, rhsDue?): areInOrder(lhsDue, rhsDue)
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): title(lhs).localizedStandardCompare(title(rhs)) == .orderedAscending
            }
        }
    }

    /// What is to come by due time, then what has passed, latest first, then the undated by title.
    func partitionedByDueDate(_ dueDate: (Element) -> Date?, title: (Element) -> String, now: Date) -> [Element] {
        sortedByDueDate(dueDate, title: title) { lhs, rhs in
            let lhsToCome = lhs >= now
            guard lhsToCome == (rhs >= now) else { return lhsToCome }
            return lhsToCome ? lhs < rhs : lhs > rhs
        }
    }
}
