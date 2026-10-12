import Foundation

/// One member of a 3+ course conflict cluster. `offset` is the
/// 0-indexed row inside the cluster where this course's block begins
/// (measured from the cluster's earliest row); `span` is the course's
/// own contiguous block length. Renderers stack these as offset-aware
/// columns so a course only paints rows it's actually scheduled in.
/// `lane` is the column the course takes: courses that never meet share one.
public struct ClassTableConflictSegment<Course> {
    public let course: Course
    public let span: Int
    public let offset: Int
    public let lane: Int

    public init(course: Course, span: Int, offset: Int, lane: Int) {
        self.course = course
        self.span = span
        self.offset = offset
        self.lane = lane
    }
}

/// Rows of one cluster member that keep one horizontal extent, in rows from the cluster's top.
/// `lanes` is every lane where the member is the only course in those rows, else its own lane.
public struct ClassTableLaneRun: Equatable {
    public let firstRow: Int
    public let rowCount: Int
    public let lanes: Range<Int>

    public init(firstRow: Int, rowCount: Int, lanes: Range<Int>) {
        self.firstRow = firstRow
        self.rowCount = rowCount
        self.lanes = lanes
    }
}

/// Greedy interval colouring for courses that overlap, shared by the class table and the Home
/// time slider. Taken by start, each interval gets the lowest lane whose last one has ended, so
/// there are only as many lanes as intervals meet at once, and courses that never meet share.
public enum OverlapLanes {
    /// Each interval's lane, in the order given, and the number of lanes. Intervals are
    /// half-open: one that ends where the next starts leaves the lane free for it.
    public static func assign<Bound: Comparable>(_ intervals: [(start: Bound, end: Bound)]) -> (lanes: [Int], count: Int) {
        // Ties keep the order given, so the course listed first takes the lower lane.
        let order = intervals.indices.sorted { (intervals[$0].start, $0) < (intervals[$1].start, $1) }
        var laneEnds: [Bound] = []
        var lanes = Array(repeating: 0, count: intervals.count)
        for index in order {
            let interval = intervals[index]
            if let free = laneEnds.firstIndex(where: { $0 <= interval.start }) {
                lanes[index] = free
                laneEnds[free] = interval.end
            } else {
                lanes[index] = laneEnds.count
                laneEnds.append(interval.end)
            }
        }
        return (lanes, laneEnds.count)
    }
}

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
    /// 3+ overlapping courses sharing a single cluster. Each segment
    /// carries its own offset/span inside `combinedSpan` so renderers
    /// can place a course only in the rows it's actually scheduled in,
    /// and its lane among `laneCount`: in an A/B/C chain A and C never
    /// meet, so they share a lane and the cluster is two lanes wide.
    /// Courses in the cluster's first row lead the array and take the
    /// lowest lanes.
    case conflictMany(
        segments: [ClassTableConflictSegment<Course>],
        combinedSpan: Int,
        laneCount: Int
    )
    /// This cell is part of a SoloStart / ConflictStart cluster that began
    /// at an earlier row; the renderer must emit nothing here so the
    /// parent's `combinedSpan` can occupy the rows.
    case skip
}

/// Pure conflict-detection algorithm shared between the iPhone main view,
/// the macOS class table, and the WeekWidget. Mirrors the iPhone
/// `ClassTableViewModel.cellRole` semantics: each cluster — whether 2-
/// or N-course — emits one `conflictStart` / `conflictMany` at its
/// earliest row plus `.skip` for every later cell. Renderers carry
/// per-course offset/span so the cluster is drawn as one staircase of
/// offset-aware columns, not a chain of overlapping per-slot pairs.
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

        if clusterStart < periodIndex { return .skip }

        if closure.count == 1 {
            let only = closure[0]
            return .solo(only.course, spanCount: only.span)
        }

        if closure.count == 2 {
            let a = closure[0]
            let b = closure[1]
            let clusterEnd = max(a.first + a.span, b.first + b.span)
            return .conflictStart(
                courseA: a.course, spanA: a.span, offsetA: a.first - clusterStart,
                courseB: b.course, spanB: b.span, offsetB: b.first - clusterStart,
                combinedSpan: clusterEnd - clusterStart
            )
        }

        // 3+ closure: one cluster with per-course offset and span, so renderers place each
        // course only in its own rows. Anchored-slot courses lead so column order matches the
        // tapped cell; recursive insertion could put a later-period course first.
        let anchoredKeys = Set(coursesHere.map(keyOf))
        let anchoredFirst = closure.filter { anchoredKeys.contains(keyOf($0.course)) }
        let rest = closure.filter { !anchoredKeys.contains(keyOf($0.course)) }
        let ordered = anchoredFirst + rest
        let (lanes, laneCount) = OverlapLanes.assign(ordered.map { (start: $0.first, end: $0.first + $0.span) })
        let segments = ordered.enumerated().map { index, entry in
            ClassTableConflictSegment(
                course: entry.course,
                span: entry.span,
                offset: entry.first - clusterStart,
                lane: lanes[index]
            )
        }
        let clusterEnd = closure.map { $0.first + $0.span }.max() ?? periodIndex
        return .conflictMany(
            segments: segments,
            combinedSpan: clusterEnd - clusterStart,
            laneCount: laneCount
        )
    }

    /// How `member` is drawn row by row: across every lane where no other member of its cluster
    /// meets, as the two-course L shape takes the full width where a course is alone, and in its
    /// own lane elsewhere. Consecutive rows with the same extent are one run.
    public static func laneRuns<C>(
        of member: ClassTableConflictSegment<C>,
        among segments: [ClassTableConflictSegment<C>],
        laneCount: Int
    ) -> [ClassTableLaneRun] {
        var runs: [ClassTableLaneRun] = []
        for row in member.offset..<(member.offset + member.span) {
            let meeting = segments.filter { $0.offset <= row && row < $0.offset + $0.span }.count
            let lanes = meeting <= 1 ? 0..<laneCount : member.lane..<(member.lane + 1)
            if let last = runs.last, last.lanes == lanes {
                runs[runs.count - 1] = ClassTableLaneRun(firstRow: last.firstRow, rowCount: last.rowCount + 1, lanes: lanes)
            } else {
                runs.append(ClassTableLaneRun(firstRow: row, rowCount: 1, lanes: lanes))
            }
        }
        return runs
    }
}
