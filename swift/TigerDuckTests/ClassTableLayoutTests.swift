import SwiftUI
import Testing
@testable import TigerDuck

struct ClassTableLayoutTests {

    private struct Course {
        let no: String
        let schedule: [Int: [String]]
    }

    private static let periods = ["1", "2", "3", "4", "5", "6"]

    private static func role(_ courses: [Course], at index: Int) -> ClassTableCellRole<Course> {
        ClassTableLayout.cellRole(
            courses: courses,
            periodIds: periods,
            weekday: 1,
            periodIndex: index,
            keyOf: \.no,
            scheduleOf: \.schedule
        )
    }

    private static func monday(_ courses: [Course]) -> [String] {
        periods.indices.map { describe(role(courses, at: $0)) }
    }

    private static func describe(_ role: ClassTableCellRole<Course>) -> String {
        switch role {
        case .empty:
            return "."
        case .skip:
            return "^"
        case let .solo(course, span):
            return "\(course.no)×\(span)"
        case let .conflictStart(a, spanA, offsetA, b, spanB, offsetB, combinedSpan):
            return "[\(a.no)@\(offsetA)×\(spanA) \(b.no)@\(offsetB)×\(spanB)]/\(combinedSpan)"
        case let .conflictMany(segments, combinedSpan, laneCount):
            let members = segments.map { "\($0.course.no)@\($0.offset)×\($0.span) L\($0.lane)" }
            return "[\(members.joined(separator: " "))]/\(combinedSpan) in \(laneCount)"
        }
    }

    @Test func anEmptyDayHasOnlyEmptyCells() {
        #expect(Self.monday([]) == [".", ".", ".", ".", ".", "."])
    }

    @Test func aRowOutsideTheGridIsEmpty() {
        let a = Course(no: "A", schedule: [1: ["1"]])
        #expect(Self.describe(Self.role([a], at: -1)) == ".")
        #expect(Self.describe(Self.role([a], at: Self.periods.count)) == ".")
    }

    @Test func aCourseCoversItsContiguousPeriods() {
        let a = Course(no: "A", schedule: [1: ["2", "3"], 2: ["1"]])
        #expect(Self.monday([a]) == [".", "A×2", "^", ".", ".", "."])
    }

    @Test func aCourseMeetingTwiceADayIsTwoBlocks() {
        let a = Course(no: "A", schedule: [1: ["1", "2", "5"]])
        #expect(Self.monday([a]) == ["A×2", "^", ".", ".", "A×1", "."])
    }

    @Test func backToBackCoursesAreSeparateBlocks() {
        let a = Course(no: "A", schedule: [1: ["1", "2"]])
        let b = Course(no: "B", schedule: [1: ["3", "4"]])
        #expect(Self.monday([a, b]) == ["A×2", "^", "B×2", "^", ".", "."])
    }

    @Test func coursesOnOtherDaysDoNotMeet() {
        let a = Course(no: "A", schedule: [1: ["1", "2"]])
        let b = Course(no: "B", schedule: [2: ["1", "2"]])
        #expect(Self.monday([a, b]) == ["A×2", "^", ".", ".", ".", "."])
    }

    @Test func twoCoursesInTheSamePeriodsAreOneCluster() {
        let a = Course(no: "A", schedule: [1: ["1", "2"]])
        let b = Course(no: "B", schedule: [1: ["1", "2"]])
        #expect(Self.monday([a, b]) == ["[A@0×2 B@0×2]/2", "^", ".", ".", ".", "."])
    }

    @Test func aPartialOverlapPlacesEachCourseInItsOwnRows() {
        let a = Course(no: "A", schedule: [1: ["1", "2", "3"]])
        let b = Course(no: "B", schedule: [1: ["2"]])
        #expect(Self.monday([a, b]) == ["[A@0×3 B@1×1]/3", "^", "^", ".", ".", "."])
    }

    @Test func aStaggeredOverlapStartsAtTheEarlierCourse() {
        let a = Course(no: "A", schedule: [1: ["2", "3"]])
        let b = Course(no: "B", schedule: [1: ["3", "4"]])
        #expect(Self.monday([b, a]) == [".", "[A@0×2 B@1×2]/3", "^", "^", ".", "."])
    }

    @Test func aChainOfThreeIsOneClusterTwoLanesWide() {
        let a = Course(no: "A", schedule: [1: ["1", "2"]])
        let b = Course(no: "B", schedule: [1: ["2", "3"]])
        let c = Course(no: "C", schedule: [1: ["3", "4"]])
        #expect(Self.monday([a, b, c]) == ["[A@0×2 L0 B@1×2 L1 C@2×2 L0]/4 in 2", "^", "^", "^", ".", "."])
    }

    @Test func coursesThatNeverMeetShareALane() {
        let long = Course(no: "P", schedule: [1: ["1", "2", "3", "4"]])
        let early = Course(no: "Q", schedule: [1: ["2"]])
        let late = Course(no: "R", schedule: [1: ["4"]])
        #expect(Self.monday([long, early, late]) == ["[P@0×4 L0 Q@1×1 L1 R@3×1 L1]/4 in 2", "^", "^", "^", ".", "."])
    }

    @Test func aCourseWhoseTwoBlocksAnotherBridgesKeepsBoth() {
        let a = Course(no: "A", schedule: [1: ["1", "2", "4", "5"]])
        let b = Course(no: "B", schedule: [1: ["2", "3", "4"]])
        #expect(Self.monday([a, b]) == ["[A@0×2 L0 A@3×2 L0 B@1×3 L1]/5 in 2", "^", "^", "^", "^", "."])
        guard case let .conflictMany(segments, _, _) = Self.role([a, b], at: 0) else {
            Issue.record("expected one cluster from period 1")
            return
        }
        #expect(segments.map(\.id) == ["A@0", "A@3", "B@1"])
    }

    @Test func threeCoursesInOnePeriodTakeThreeLanes() {
        let courses = ["A", "B", "C"].map { Course(no: $0, schedule: [1: ["1", "2"]]) }
        #expect(Self.monday(courses) == ["[A@0×2 L0 B@0×2 L1 C@0×2 L2]/2 in 3", "^", ".", ".", ".", "."])
    }
}

struct OverlapLanesTests {

    @Test func overlappingIntervalsTakeSeparateLanes() {
        let assigned = OverlapLanes.assign([(start: 0, end: 2), (start: 1, end: 3)])
        #expect(assigned.lanes == [0, 1])
        #expect(assigned.count == 2)
    }

    @Test func backToBackIntervalsShareALane() {
        let assigned = OverlapLanes.assign([(start: 0, end: 2), (start: 2, end: 4)])
        #expect(assigned.lanes == [0, 0])
        #expect(assigned.count == 1)
    }

    @Test func lanesFollowTheStartsAndTiesKeepTheOrderGiven() {
        let assigned = OverlapLanes.assign([(start: 2, end: 4), (start: 0, end: 3), (start: 0, end: 1)])
        #expect(assigned.lanes == [1, 0, 1])
        #expect(assigned.count == 2)
    }

    @Test func noIntervalsTakeNoLanes() {
        let assigned = OverlapLanes.assign([(start: Int, end: Int)]())
        #expect(assigned.lanes.isEmpty)
        #expect(assigned.count == 0)
    }
}

struct ClassTableLaneRunTests {

    private static func segment(_ no: String, offset: Int, span: Int, lane: Int) -> ClassTableConflictSegment<String> {
        ClassTableConflictSegment(course: no, key: no, span: span, offset: offset, lane: lane)
    }

    @Test func aChainsEndsWidenWhereTheyAreAlone() {
        let a = Self.segment("A", offset: 0, span: 2, lane: 0)
        let b = Self.segment("B", offset: 1, span: 2, lane: 1)
        let c = Self.segment("C", offset: 2, span: 2, lane: 0)
        let all = [a, b, c]

        #expect(ClassTableLayout.laneRuns(of: a, among: all, laneCount: 2) == [
            ClassTableLaneRun(firstRow: 0, rowCount: 1, lanes: 0..<2),
            ClassTableLaneRun(firstRow: 1, rowCount: 1, lanes: 0..<1),
        ])
        #expect(ClassTableLayout.laneRuns(of: b, among: all, laneCount: 2) == [
            ClassTableLaneRun(firstRow: 1, rowCount: 2, lanes: 1..<2),
        ])
        #expect(ClassTableLayout.laneRuns(of: c, among: all, laneCount: 2) == [
            ClassTableLaneRun(firstRow: 2, rowCount: 1, lanes: 0..<1),
            ClassTableLaneRun(firstRow: 3, rowCount: 1, lanes: 0..<2),
        ])
    }

    @Test func aLongCourseNarrowsOnlyBesideTheOthers() {
        let long = Self.segment("P", offset: 0, span: 4, lane: 0)
        let all = [long, Self.segment("Q", offset: 1, span: 1, lane: 1), Self.segment("R", offset: 3, span: 1, lane: 1)]

        #expect(ClassTableLayout.laneRuns(of: long, among: all, laneCount: 2) == [
            ClassTableLaneRun(firstRow: 0, rowCount: 1, lanes: 0..<2),
            ClassTableLaneRun(firstRow: 1, rowCount: 1, lanes: 0..<1),
            ClassTableLaneRun(firstRow: 2, rowCount: 1, lanes: 0..<2),
            ClassTableLaneRun(firstRow: 3, rowCount: 1, lanes: 0..<1),
        ])
    }
}


struct ConflictLaneShapeTests {

    @Test func aCourseThatNarrowsIsOneShapeAndLeavesTheSeamOpen() {
        let geometry = ConflictLaneGeometry(width: 100, laneCount: 2, cellHeight: 50, rowSpacing: 4)
        let runs = [
            ClassTableLaneRun(firstRow: 0, rowCount: 1, lanes: 0..<2),
            ClassTableLaneRun(firstRow: 1, rowCount: 1, lanes: 0..<1),
        ].map(geometry.rect)
        #expect(runs == [CGRect(x: 0, y: 0, width: 100, height: 50), CGRect(x: 0, y: 54, width: 48, height: 50)])

        let path = ConflictLaneShape(runs: runs, cornerRadius: 8).path(in: CGRect(x: 0, y: 0, width: 100, height: 104))

        #expect(path.contains(CGPoint(x: 75, y: 25)))
        #expect(path.contains(CGPoint(x: 24, y: 79)))
        #expect(path.contains(CGPoint(x: 24, y: 52)), "the seam is bridged inside the course's own lane")
        #expect(!path.contains(CGPoint(x: 75, y: 79)), "the second course's lane stays free")
        #expect(!path.contains(CGPoint(x: 75, y: 52)), "the seam above the second course stays open")
    }

    @Test func theOutlineKeepsOnlyRealCorners() {
        let points = [
            CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: 48, y: 50), CGPoint(x: 48, y: 54),
            CGPoint(x: 48, y: 54), CGPoint(x: 48, y: 104), CGPoint(x: 0, y: 104), CGPoint(x: 0, y: 54),
            CGPoint(x: 0, y: 54), CGPoint(x: 0, y: 50), CGPoint(x: 0, y: 50), CGPoint(x: 0, y: 0),
        ]
        #expect(ConflictLaneShape.corners(of: points) == [
            CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: 48, y: 50),
            CGPoint(x: 48, y: 104), CGPoint(x: 0, y: 104), CGPoint(x: 0, y: 0),
        ])
    }
}
