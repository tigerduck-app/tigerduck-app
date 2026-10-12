import Testing
@testable import TigerDuck

/// The conflict layout behind the iPhone grid, the Mac grid and the week widget: which cell
/// starts a block, which cells it covers, and where each overlapping course sits in it.
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

    /// Monday's cells top to bottom: `.` empty, `^` covered by a block above, `A×2` a course alone
    /// over two rows, and `[A@0×3 B@1×1]/3` a cluster three rows tall with each course's first
    /// row and row count.
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
        case let .conflictMany(segments, combinedSpan):
            let members = segments.map { "\($0.course.no)@\($0.offset)×\($0.span)" }
            return "[\(members.joined(separator: " "))]/\(combinedSpan)"
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

    /// Each course keeps to its own rows, so B is not drawn in periods 1 and 3.
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

    /// A on 1-2, B on 2-3 and C on 3-4: A and C never meet, but B bridges them, so the three
    /// are one cluster from period 1 to 4.
    @Test func aChainOfThreeIsOneCluster() {
        let a = Course(no: "A", schedule: [1: ["1", "2"]])
        let b = Course(no: "B", schedule: [1: ["2", "3"]])
        let c = Course(no: "C", schedule: [1: ["3", "4"]])
        #expect(Self.monday([a, b, c]) == ["[A@0×2 B@1×2 C@2×2]/4", "^", "^", "^", ".", "."])
    }
}
