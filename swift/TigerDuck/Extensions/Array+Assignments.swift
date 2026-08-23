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

    func ignoredSorted() -> [SDAssignment] {
        filter { $0.isArchived }
            .sorted { $0.dueDate < $1.dueDate }
    }

    func hasIgnored() -> Bool {
        contains { $0.isArchived }
    }

    /// Time-agnostic candidate set for the 全部 tab. Excludes locally-archived
    /// rows (they belong to the 已忽略 filter) *except* when Moodle has since
    /// marked the row submitted: the archive flag persists separately from
    /// Moodle completion, and a row the school now considers handed in has
    /// stopped being work the user chose to hide.
    ///
    /// The exception used to be justified by 已忽略 requiring `!isCompleted`,
    /// so that the row would not vanish from every filter. That stopped being
    /// true in `12a8687` — ``ignoredSorted()`` keys off the archive flag alone
    /// now, so the row is reachable either way and this only decides whether
    /// 全部 also shows it.
    /// Intentionally unsorted — the past/future partition depends on the
    /// live clock and must be applied at render time via
    /// `partitionedByDueDate(now:)`, not cached against a frozen `Date()`.
    func allCandidates() -> [SDAssignment] {
        filter { !$0.isArchived || $0.isCompleted }
    }

    /// Splits assignments into future-first and past-second buckets
    /// relative to `now`:
    ///   • future bucket sorted ascending — the next deadline is on top
    ///   • past bucket sorted descending — most-recently-due first so the
    ///     just-passed work is right under the future cutoff
    /// Call this from the view layer (paired with `TimelineView`) so a row
    /// whose `dueDate` has just crossed `now` migrates to the past bucket
    /// on the next minute tick instead of staying stuck in "future".
    func partitionedByDueDate(now: Date) -> [SDAssignment] {
        let future = filter { $0.dueDate >= now }.sorted { $0.dueDate < $1.dueDate }
        let past = filter { $0.dueDate < now }.sorted { $0.dueDate > $1.dueDate }
        return future + past
    }
}
