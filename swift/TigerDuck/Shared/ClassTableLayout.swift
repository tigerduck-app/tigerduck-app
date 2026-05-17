import Foundation

/// Per-cell role produced by the class-table conflict-detection algorithm.
/// Generic so the same value can carry an `SDCourse` (main app), a
/// `SnapshotCourse` (WidgetKit), or any future surface's course model.
public enum ClassTableCellRole<Course> {
    case empty
    case solo(Course, spanCount: Int)
    /// Two overlapping courses occupying (possibly partially) this cluster.
    /// `combinedSpan` is the total row count of the union;
    /// `offsetA` / `offsetB` are 0-indexed row positions within the cluster
    /// where each course's block begins; `spanA` / `spanB` are each course's
    /// own contiguous block length.
    case conflictStart(
        courseA: Course, spanA: Int, offsetA: Int,
        courseB: Course, spanB: Int, offsetB: Int,
        combinedSpan: Int
    )
    /// 3+ overlapping courses occupying the same row run. Offsets aren't
    /// tracked individually because callers reach this case through the
    /// per-slot fallback, where every member shares the same span starting
    /// at the current row. Renderers should split horizontally across
    /// `courses` so no course disappears from the grid.
    case conflictMany(courses: [Course], combinedSpan: Int)
    /// This cell is part of a SoloStart / ConflictStart cluster that began
    /// at an earlier row; the renderer must emit nothing here so the
    /// parent's `combinedSpan` can occupy the rows.
    case skip
}

/// Pure conflict-detection algorithm shared between the iPhone main view,
/// the macOS class table, and the WeekWidget. Mirrors the iPhone
/// `ClassTableViewModel.cellRole` semantics: 2-course overlaps emit a
/// `conflictStart` at the cluster's earliest row plus `.skip` for every
/// later cell in that cluster; a transitive closure of 3+ courses falls
/// back to per-slot rendering so no course is dropped.
public enum ClassTableLayout {
    /// Returns the role for one cell, given a flat list of courses, the
    /// chronologically-ordered period ids for the grid, and key/schedule
    /// accessors. The algorithm is O(periods²) per call — acceptable for
    /// the ≤14 period rows the school uses.
    public static func cellRole<C>(
        courses: [C],
        periodIds: [String],
        weekday: Int,
        periodIndex: Int,
        keyOf: (C) -> String,
        scheduleOf: (C) -> [Int: [String]]
    ) -> ClassTableCellRole<C> {
        guard periodIndex >= 0, periodIndex < periodIds.count else { return .empty }

        func coursesAt(_ idx: Int) -> [C] {
            guard idx >= 0, idx < periodIds.count else { return [] }
            let pid = periodIds[idx]
            return courses.filter { (scheduleOf($0)[weekday] ?? []).contains(pid) }
        }

        let coursesHere = coursesAt(periodIndex)
        guard !coursesHere.isEmpty else { return .empty }

        // Transitive closure of overlapping blocks rooted at this cell.
        var closure: [(course: C, first: Int, span: Int)] = []
        var seenKeys = Set<String>()

        func addCourse(_ c: C, seedIndex: Int) {
            guard seenKeys.insert(keyOf(c)).inserted else { return }
            let key = keyOf(c)
            var first = seedIndex
            while first - 1 >= 0,
                  coursesAt(first - 1).contains(where: { keyOf($0) == key }) {
                first -= 1
            }
            var last = seedIndex
            while last + 1 < periodIds.count,
                  coursesAt(last + 1).contains(where: { keyOf($0) == key }) {
                last += 1
            }
            let span = last - first + 1
            closure.append((c, first, span))
            for i in first..<(first + span) {
                for other in coursesAt(i) where !seenKeys.contains(keyOf(other)) {
                    addCourse(other, seedIndex: i)
                }
            }
        }
        for c in coursesHere { addCourse(c, seedIndex: periodIndex) }

        let clusterStart = closure.map(\.first).min() ?? periodIndex

        // 3+ closure → per-slot fallback so every course stays on the grid.
        if closure.count >= 3 {
            return perSlotRole(
                periodIds: periodIds,
                periodIndex: periodIndex,
                coursesHere: coursesHere,
                coursesAt: coursesAt,
                keyOf: keyOf
            )
        }

        if clusterStart < periodIndex { return .skip }

        if closure.count == 1 {
            let only = closure[0]
            return .solo(only.course, spanCount: only.span)
        }

        let a = closure[0]
        let b = closure[1]
        let clusterEnd = max(a.first + a.span, b.first + b.span)
        return .conflictStart(
            courseA: a.course, spanA: a.span, offsetA: a.first - clusterStart,
            courseB: b.course, spanB: b.span, offsetB: b.first - clusterStart,
            combinedSpan: clusterEnd - clusterStart
        )
    }

    private static func perSlotRole<C>(
        periodIds: [String],
        periodIndex: Int,
        coursesHere: [C],
        coursesAt: (Int) -> [C],
        keyOf: (C) -> String
    ) -> ClassTableCellRole<C> {
        let mySet = Set(coursesHere.map(keyOf))

        if periodIndex > 0 {
            let prev = coursesAt(periodIndex - 1)
            if Set(prev.map(keyOf)) == mySet { return .skip }
        }

        var span = 1
        var i = periodIndex + 1
        while i < periodIds.count {
            let next = coursesAt(i)
            if Set(next.map(keyOf)) == mySet {
                span += 1
                i += 1
            } else {
                break
            }
        }

        if coursesHere.count == 1 {
            return .solo(coursesHere[0], spanCount: span)
        }
        if coursesHere.count == 2 {
            return .conflictStart(
                courseA: coursesHere[0], spanA: span, offsetA: 0,
                courseB: coursesHere[1], spanB: span, offsetB: 0,
                combinedSpan: span
            )
        }
        return .conflictMany(courses: coursesHere, combinedSpan: span)
    }
}
