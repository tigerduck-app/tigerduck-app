import Foundation
import Testing
@testable import TigerDuck

/// A course can meet twice a day in two rooms. What opens one block shows that block's room and
/// time, not the whole day's (https://github.com/tigerduck-app/tigerduck-app/issues/517).
@MainActor
struct CourseBlockSelectionTests {
    private static func twiceOnMonday() -> SDCourse {
        SDCourse(
            courseNo: "TEST0517",
            courseName: "Test",
            classroom: "TR-313, IB-503",
            schedule: [1: ["3", "4", "7", "8"]],
            classroomMap: ["1-3": "TR-313", "1-4": "TR-313", "1-7": "IB-503", "1-8": "IB-503"]
        )
    }

    @Test("the Current class card shows the running block's room")
    func currentClassShowsItsBlocksRoom() throws {
        let info = try #require([Self.twiceOnMonday()].ongoingCourses(weekday: 1, minuteOfDay: 10 * 60 + 30).first)
        #expect(info.periods == ["3", "4"])
        #expect(info.classroom == "TR-313")
    }

    @Test("a tapped cell opens its block's time and room")
    func aTappedCellOpensItsBlock() {
        let course = Self.twiceOnMonday()
        let viewModel = ClassTableViewModel()
        viewModel.selectCourse(course, weekday: 1, periodId: "8")
        #expect(viewModel.selectedCoursePeriods == ["7", "8"])
        #expect(viewModel.selectedCourseTimeRange == "14:20 - 16:20")
        #expect(CourseDetailSheet.classroom(of: course, weekday: 1, periods: viewModel.selectedCoursePeriods) == "IB-503")
    }

    /// The conflict picker names the cluster's first period, where the picked course may start later.
    @Test("a course picked from a conflict opens the block that starts in the cluster")
    func aConflictPickOpensTheBlockInTheCluster() {
        let viewModel = ClassTableViewModel()
        viewModel.selectCourse(Self.twiceOnMonday(), weekday: 1, periodId: "6")
        #expect(viewModel.selectedCoursePeriods == ["7", "8"])
    }

    @Test("a Current class tap opens the running block")
    func aCurrentClassTapOpensTheRunningBlock() throws {
        let course = Self.twiceOnMonday()
        let info = try #require([course].ongoingCourses(weekday: 1, minuteOfDay: 10 * 60 + 30).first)
        let viewModel = ClassTableViewModel()
        viewModel.selectOngoing(info)
        #expect(viewModel.selectedCourseTimeRange == "10:20 - 12:10")
        #expect(CourseDetailSheet.classroom(of: course, weekday: 1, periods: viewModel.selectedCoursePeriods) == "TR-313")
    }

    @Test("without a block the sheet lists the day's rooms")
    func withoutABlockTheDaysRoomsShow() {
        #expect(CourseDetailSheet.classroom(of: Self.twiceOnMonday(), weekday: 1, periods: nil) == "TR-313, IB-503")
    }
}

/// Switching terms shows the cached list, then fetches the term again. The fetch has to replace
/// what is on screen when a course comes back changed, not only when the set of courses changes
/// (https://github.com/tigerduck-app/tigerduck-app/issues/518).
@MainActor
struct ClassTableRefreshTests {
    private static func course(
        name: String = "Test",
        schedule: [Int: [String]] = [1: ["3", "4"]],
        rooms: [String: String] = ["1-3": "TR-313", "1-4": "TR-313"]
    ) -> SDCourse {
        SDCourse(courseNo: "TEST0518", courseName: name, classroom: "TR-313", schedule: schedule, classroomMap: rooms)
    }

    @Test("a course back with a new room, time or name replaces the shown one")
    func aChangedCourseReplacesTheShownOne() {
        let shown = [Self.course()]
        #expect(!ClassTableViewModel.showsChange([Self.course()], over: shown))
        #expect(ClassTableViewModel.showsChange([Self.course(rooms: ["1-3": "IB-503", "1-4": "IB-503"])], over: shown))
        #expect(ClassTableViewModel.showsChange([Self.course(schedule: [2: ["3", "4"]])], over: shown))
        #expect(ClassTableViewModel.showsChange([Self.course(name: "Renamed")], over: shown))
    }
}
