import Foundation

extension Array where Element == SDAssignment {
    func unfinished(for courseNo: String) -> [SDAssignment] {
        filter { $0.courseNo == courseNo && !$0.isCompleted && !$0.isArchived && !$0.isLocallyCompleted }
    }

    func hasUnfinished(for courseNo: String) -> Bool {
        contains { $0.courseNo == courseNo && !$0.isCompleted && !$0.isArchived && !$0.isLocallyCompleted }
    }

    /// Returns incomplete assignments sorted by due date ascending.
    /// Excludes locally archived and locally-completed items (hidden in 未完成 tab).
    func upcomingSorted() -> [SDAssignment] {
        filter { !$0.isCompleted && !$0.isArchived && !$0.isLocallyCompleted }
            .sorted { $0.dueDate < $1.dueDate }
    }

    /// Returns ignored-but-still-unsubmitted assignments sorted by due date
    /// ascending. If Moodle later marks an assignment completed, it no longer
    /// belongs in the ignored bucket even if a stale local flag still exists.
    func ignoredSorted() -> [SDAssignment] {
        filter { !$0.isCompleted && $0.isArchived }
            .sorted { $0.dueDate < $1.dueDate }
    }

    func hasIgnored() -> Bool {
        contains { !$0.isCompleted && $0.isArchived }
    }

    /// Returns all assignments split into future-first and past-second
    /// buckets relative to `now`:
    ///   • future bucket sorted ascending — the next deadline is on top
    ///   • past bucket sorted descending — most-recently-due first so the
    ///     just-passed work is right under the future cutoff
    /// Ignored-but-unsubmitted items are excluded because they live in the
    /// dedicated 已忽略 filter.
    func allSorted(now: Date = Date()) -> [SDAssignment] {
        let visible = filter { !$0.isArchived }
        let future = visible.filter { $0.dueDate >= now }.sorted { $0.dueDate < $1.dueDate }
        let past = visible.filter { $0.dueDate < now }.sorted { $0.dueDate > $1.dueDate }
        return future + past
    }
}
