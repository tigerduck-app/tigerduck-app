// Grid geometry and 衝堂 resolution for the class table — split out of
// ClassTableViewModel.swift.
//
// A course spans contiguous periods; two or more can share a slot; and
// three or more can chain transitively through a bridging course, so the
// whole cluster has to be laid out together. Selecting a cell that holds
// a conflict routes through the picker rather than guessing which course
// the tap meant.

import Defaults
import SwiftUI

extension ClassTableViewModel {

    struct ConflictSegment: Equatable {
        let course: SDCourse
        /// Contiguous block length in rows.
        let span: Int
        /// 0-indexed row offset from the cluster's `clusterStart` where
        /// this course's block begins.
        let offset: Int
    }

    enum CellRole {
        case empty
        case solo(SDCourse, spanCount: Int)
        /// Two or more overlapping courses sharing a cluster.
        /// `combinedSpan` is the total row count of the union of every
        /// segment's block; each segment's `offset` / `span` place it
        /// inside that union. The renderer keeps the L-split layout for
        /// the 2-course case and falls back to a column layout when a
        /// chain pulls in 3+ courses (so every scheduled period stays
        /// visible — no row gets buried under a `.skip` with nothing
        /// drawn on top).
        case conflictStart(segments: [ConflictSegment], combinedSpan: Int)
        /// This cell is part of a SoloStart / ConflictStart cluster that
        /// began at an earlier row; the renderer must emit nothing here so
        /// the parent's `combinedSpan` overlay can occupy the rows.
        case skip
    }

    /// Walks backward and forward from `startIndex` through `activePeriods`,
    /// collecting the contiguous block where `course` is present. Returns
    /// (firstIndex, span). Used by the conflict-cluster algorithm so block
    /// extents are computed against the same chronological ordering the
    /// grid renders.
    private func blockFor(weekday: Int, startIndex: Int, course: SDCourse) -> (first: Int, span: Int) {
        let periods = activePeriods
        let courseNo = course.courseNo

        var first = startIndex
        while first - 1 >= 0 {
            let prev = periods[first - 1]
            let present = courses(for: weekday, period: prev.id).contains { $0.courseNo == courseNo }
            if present { first -= 1 } else { break }
        }
        var last = startIndex
        while last + 1 < periods.count {
            let next = periods[last + 1]
            let present = courses(for: weekday, period: next.id).contains { $0.courseNo == courseNo }
            if present { last += 1 } else { break }
        }
        return (first, last - first + 1)
    }

    func cellRole(weekday: Int, periodIndex: Int) -> CellRole {
        let key = CellRoleKey(weekday: weekday, periodIndex: periodIndex)
        if let cached = cellRoleCache[key] { return cached }

        let periods = activePeriods
        guard periodIndex >= 0, periodIndex < periods.count else {
            cellRoleCache[key] = .empty
            return .empty
        }
        let period = periods[periodIndex]
        let coursesHere = courses(for: weekday, period: period.id)
        if coursesHere.isEmpty {
            cellRoleCache[key] = .empty
            return .empty
        }

        // Build transitive closure of courses whose blocks overlap with any
        // course already in the cluster, rooted at the courses present in
        // this cell. This guarantees we emit a `conflictStart` at the
        // earliest row of the union and `.skip` thereafter.
        var closure: [(course: SDCourse, first: Int, span: Int)] = []
        var seen: Set<String> = []

        func addCourse(_ c: SDCourse, seedIndex: Int) {
            if !seen.insert(c.courseNo).inserted { return }
            let block = blockFor(weekday: weekday, startIndex: seedIndex, course: c)
            closure.append((c, block.first, block.span))
            for i in block.first..<(block.first + block.span) {
                guard let pid = periods[safe: i]?.id else { continue }
                for other in courses(for: weekday, period: pid) where !seen.contains(other.courseNo) {
                    addCourse(other, seedIndex: i)
                }
            }
        }
        for c in coursesHere { addCourse(c, seedIndex: periodIndex) }

        let clusterStart = closure.map(\.first).min() ?? periodIndex

        if clusterStart < periodIndex {
            cellRoleCache[key] = .skip
            return .skip
        }

        if closure.count == 1 {
            let only = closure[0]
            let role = CellRole.solo(only.course, spanCount: only.span)
            cellRoleCache[key] = role
            return role
        }

        // Emit a segment per course in the closure so a 3+ chain
        // (e.g. A on periods 1-2, B on 2-3, C on 3-4) keeps every
        // scheduled period visible. Earlier code capped the cluster at
        // two segments, which left the third course's tail covered by
        // `.skip` but not drawn over — hiding scheduled class time.
        // Anchored-slot courses lead the array so the rendering order
        // matches the cell the user tapped; the rest follow in
        // closure-insertion order.
        let anchoredNos = Set(coursesHere.map(\.courseNo))
        let anchoredFirst = closure.filter { anchoredNos.contains($0.course.courseNo) }
        let rest = closure.filter { !anchoredNos.contains($0.course.courseNo) }
        let ordered = anchoredFirst + rest
        let segments = ordered.map { entry in
            ConflictSegment(
                course: entry.course,
                span: entry.span,
                offset: entry.first - clusterStart
            )
        }
        let clusterEnd = closure.map { $0.first + $0.span }.max() ?? periodIndex
        let role = CellRole.conflictStart(
            segments: segments,
            combinedSpan: clusterEnd - clusterStart
        )
        cellRoleCache[key] = role
        return role
    }

    struct ConflictPickerTarget: Identifiable {
        let id = UUID()
        let courses: [SDCourse]
        let weekday: Int
        let periodId: String
    }

    struct TripleConflictError: Identifiable {
        let id = UUID()
        let weekday: Int
        let periodId: String
        let newCourseName: String
        let existingA: SDCourse
        let existingB: SDCourse
    }

    /// Scans every slot the candidate would occupy and returns the first
    /// slot that already has two courses — adding the candidate there would
    /// push it to three. Returns nil when the add is safe.
    func wouldCauseTripleConflict(_ candidate: SDCourse) -> TripleConflictError? {
        for (weekday, periodIds) in candidate.schedule {
            for pid in periodIds {
                let existing = courses(for: weekday, period: pid)
                if existing.count >= 2 {
                    return TripleConflictError(
                        weekday: weekday,
                        periodId: pid,
                        newCourseName: candidate.displayName,
                        existingA: existing[0],
                        existingB: existing[1]
                    )
                }
            }
        }
        return nil
    }

    func presentConflictPicker(courseA: SDCourse, courseB: SDCourse, weekday: Int, periodId: String) {
        // Surface every course in the cluster's transitive closure — the
        // L-render is capped at two courses, but a 3+ chain (e.g. A+C
        // anchored here and A+B at the next period) must keep all of
        // them reachable through the picker so the third never becomes
        // unselectable.
        var resolved = conflictClosureCourses(weekday: weekday, periodId: periodId)
        if resolved.isEmpty {
            resolved = [courseA, courseB]
        } else {
            // Guarantee the two displayed courses lead the list — the
            // picker rows then match the L cluster the user just tapped.
            let displayed = [courseA, courseB]
            let displayedNos = Set(displayed.map(\.courseNo))
            resolved = displayed + resolved.filter { !displayedNos.contains($0.courseNo) }
        }
        conflictPickerTarget = ConflictPickerTarget(
            courses: resolved,
            weekday: weekday,
            periodId: periodId
        )
    }

    /// Walk the same transitive-closure logic `cellRole` uses, but return
    /// the full list of courses involved in the conflict cluster anchored
    /// at `(weekday, periodId)`. Used by the picker so a 3+ course chain
    /// surfaces every course, even though the L-cluster only renders two.
    private func conflictClosureCourses(weekday: Int, periodId: String) -> [SDCourse] {
        let periods = activePeriods
        guard let periodIndex = periods.firstIndex(where: { $0.id == periodId }) else {
            return []
        }
        var resolved: [SDCourse] = []
        var seen: Set<String> = []
        func add(_ c: SDCourse, seedIndex: Int) {
            guard seen.insert(c.courseNo).inserted else { return }
            resolved.append(c)
            let block = blockFor(weekday: weekday, startIndex: seedIndex, course: c)
            for i in block.first..<(block.first + block.span) {
                guard let pid = periods[safe: i]?.id else { continue }
                for other in courses(for: weekday, period: pid)
                where !seen.contains(other.courseNo) {
                    add(other, seedIndex: i)
                }
            }
        }
        for c in courses(for: weekday, period: periodId) {
            add(c, seedIndex: periodIndex)
        }
        return resolved
    }

    func pickFromConflict(_ course: SDCourse) {
        guard let target = conflictPickerTarget else { return }
        let weekday = target.weekday
        let periodId = target.periodId
        conflictPickerTarget = nil
        selectCourse(course, weekday: weekday, periodId: periodId)
    }

    func selectCourse(_ course: SDCourse, weekday: Int, periodId: String) {
        selectedWeekday = weekday
        selectedPeriodId = periodId
        selectedCourseBlockTimeRange = nil
        selectedCourse = course
    }

    /// Carousel "Current class" card tap. Carries the block's exact
    /// start/end so the detail sheet shows the tapped block's time
    /// (e.g. periods 3-4 → "10:20 - 12:10") instead of falling back
    /// to `course.timeRange(for:)`, which lumps split same-day blocks
    /// into one whole-day span.
    func selectOngoing(_ info: OngoingCourseInfo) {
        selectedWeekday = info.weekday
        selectedPeriodId = info.firstPeriodId
        selectedCourseBlockTimeRange = info.formattedTimeRange
        selectedCourse = info.course
    }

    /// Returns `true` iff `course` was newly appended to `courses`. The
}
