import Foundation

public struct ClassTableConflictSegment<Course>: Identifiable {
    public let course: Course
    public let key: String
    public let span: Int
    public let offset: Int
    public let lane: Int

    public var id: String { "\(key)@\(offset)" }

    public init(course: Course, key: String, span: Int, offset: Int, lane: Int) {
        self.course = course
        self.key = key
        self.span = span
        self.offset = offset
        self.lane = lane
    }
}

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

public enum OverlapLanes {
    public static func assign<Bound: Comparable>(_ intervals: [(start: Bound, end: Bound)]) -> (lanes: [Int], count: Int) {
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

public enum ClassTableCellRole<Course> {
    case empty
    case solo(Course, spanCount: Int)
    case conflictStart(
        courseA: Course, spanA: Int, offsetA: Int,
        courseB: Course, spanB: Int, offsetB: Int,
        combinedSpan: Int
    )
    case conflictMany(
        segments: [ClassTableConflictSegment<Course>],
        combinedSpan: Int,
        laneCount: Int
    )
    case skip
}

public enum ClassTableLayout {
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

        var closure: [(course: C, first: Int, span: Int)] = []
        var seenBlocks = Set<ClusterBlock>()

        func addCourse(_ c: C, seedIndex: Int) {
            let key = keyOf(c)
            var first = seedIndex
            while first - 1 >= 0,
                  coursesAt(first - 1).contains(where: { keyOf($0) == key }) {
                first -= 1
            }
            guard seenBlocks.insert(ClusterBlock(key: key, first: first)).inserted else { return }
            var last = seedIndex
            while last + 1 < periodIds.count,
                  coursesAt(last + 1).contains(where: { keyOf($0) == key }) {
                last += 1
            }
            let span = last - first + 1
            closure.append((c, first, span))
            for i in first..<(first + span) {
                for other in coursesAt(i) {
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

        let anchoredKeys = Set(coursesHere.map(keyOf))
        let anchoredFirst = closure.filter { anchoredKeys.contains(keyOf($0.course)) }
        let rest = closure.filter { !anchoredKeys.contains(keyOf($0.course)) }
        let ordered = anchoredFirst + rest
        let (lanes, laneCount) = OverlapLanes.assign(ordered.map { (start: $0.first, end: $0.first + $0.span) })
        let segments = ordered.enumerated().map { index, entry in
            ClassTableConflictSegment(
                course: entry.course,
                key: keyOf(entry.course),
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

private struct ClusterBlock: Hashable {
    let key: String
    let first: Int
}
