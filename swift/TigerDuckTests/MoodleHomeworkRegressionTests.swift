import Foundation
import Testing
@testable import TigerDuck

struct MoodleHomeworkRegressionTests {
    @Test func moodleDeepLink_usesFetchedMoodleUrl() {
        let assignment = SDAssignment(
            assignmentId: "event-42",
            courseNo: "EC1013701",
            courseName: "資料結構",
            title: "HW1",
            dueDate: Date(),
            moodleUrl: "https://moodle2.ntust.edu.tw/mod/assign/view.php?id=12345"
        )

        #expect(
            assignment.moodleDeepLink?.absoluteString
                == "moodlemobile://https://moodle2.ntust.edu.tw?redirect=/mod/assign/view.php?id%3D12345"
        )
    }

    @Test func courseNoFromMoodleId_onlyStripsNumericSemesterPrefix() {
        #expect(SDCourse.courseNoFromMoodleId("1142EC1013701") == "EC1013701")
        #expect(SDCourse.courseNoFromMoodleId("EC1013701") == "EC1013701")
    }

    @Test func moodleDeepLink_returnsNilWithoutFetchedMoodleUrl() {
        let assignment = SDAssignment(
            assignmentId: "123",
            courseNo: "EC1013701",
            courseName: "資料結構",
            title: "HW1",
            dueDate: Date(),
            moodleUrl: nil
        )

        #expect(assignment.moodleDeepLink == nil)
    }

    @Test func semesterCacheIsolation_savingOneSemesterDoesNotAffectAnother() {
        let cache = DataCache.shared
        let semA = "TEST_ISO_1142"
        let semB = "TEST_ISO_1141"
        defer {
            cache.saveCourses([], semester: semA)
            cache.saveCourses([], semester: semB)
        }

        let courseA = SDCourse(courseNo: "AAA001", courseName: "Course A", semester: semA)
        let courseB = SDCourse(courseNo: "BBB002", courseName: "Course B", semester: semB)

        cache.saveCourses([courseA], semester: semA)
        cache.saveCourses([courseB], semester: semB)

        let loadedA = cache.loadCourses(semester: semA)
        let loadedB = cache.loadCourses(semester: semB)

        #expect(loadedA.map(\.courseNo) == ["AAA001"])
        #expect(loadedB.map(\.courseNo) == ["BBB002"])
    }

    @Test func moodleEnrolledCourse_extractsSemesterAndCourseNoFromIdnumber() {
        let course = MoodleEnrolledCourse(
            id: 1,
            fullname: "AI",
            shortname: "ai",
            idnumber: "1142EC1013701",
            startDate: nil,
            endDate: nil
        )
        #expect(course.semester == "1142")
        #expect(course.courseNo == "EC1013701")
    }

    @Test func moodleEnrolledCourse_emptyIdnumberYieldsEmptyDerivedFields() {
        let course = MoodleEnrolledCourse(
            id: 1,
            fullname: "X",
            shortname: "x",
            idnumber: "",
            startDate: nil,
            endDate: nil
        )
        #expect(course.semester == "")
        #expect(course.courseNo == "")
    }

    @Test func moodleSubmissionStatus_isSubmittedReflectsServerStatus() {
        let submitted = MoodleSubmissionStatus(assignId: 1, submissionStatus: "submitted", gradingStatus: "graded")
        let draft = MoodleSubmissionStatus(assignId: 2, submissionStatus: "draft", gradingStatus: nil)
        let new = MoodleSubmissionStatus(assignId: 3, submissionStatus: "new", gradingStatus: nil)
        let absent = MoodleSubmissionStatus(assignId: 4, submissionStatus: nil, gradingStatus: nil)

        #expect(submitted.isSubmitted)
        #expect(!draft.isSubmitted)
        #expect(!new.isSubmitted)
        #expect(!absent.isSubmitted)
    }

    @Test func arrayUpcomingSorted_excludesCompletedAndOrdersByDueDateAscending() {
        let now = Date()
        let pastIncomplete = SDAssignment(
            assignmentId: "1", courseNo: "CN1", courseName: "C1", title: "Past",
            dueDate: now.addingTimeInterval(-86400), isCompleted: false
        )
        let futureIncomplete = SDAssignment(
            assignmentId: "2", courseNo: "CN1", courseName: "C1", title: "Future",
            dueDate: now.addingTimeInterval(86400), isCompleted: false
        )
        let completed = SDAssignment(
            assignmentId: "3", courseNo: "CN1", courseName: "C1", title: "Done",
            dueDate: now.addingTimeInterval(3600), isCompleted: true
        )

        let result = [futureIncomplete, completed, pastIncomplete].upcomingSorted()
        #expect(result.map(\.assignmentId) == ["1", "2"])
    }

    @Test func arrayAllSorted_putsIncompleteAscendingBeforeCompletedDescending() {
        let now = Date()
        let incompleteA = SDAssignment(
            assignmentId: "i1", courseNo: "C", courseName: "C", title: "iA",
            dueDate: now.addingTimeInterval(-3600), isCompleted: false
        )
        let incompleteB = SDAssignment(
            assignmentId: "i2", courseNo: "C", courseName: "C", title: "iB",
            dueDate: now.addingTimeInterval(7200), isCompleted: false
        )
        let completedA = SDAssignment(
            assignmentId: "c1", courseNo: "C", courseName: "C", title: "cA",
            dueDate: now.addingTimeInterval(-7200), isCompleted: true
        )
        let completedB = SDAssignment(
            assignmentId: "c2", courseNo: "C", courseName: "C", title: "cB",
            dueDate: now.addingTimeInterval(3600), isCompleted: true
        )

        let result = [completedA, incompleteB, completedB, incompleteA].allSorted()
        #expect(result.map(\.assignmentId) == ["i1", "i2", "c2", "c1"])
    }

    @Test func classTableViewModel_displayLabel_formatsSemesterCode() {
        let vm = ClassTableViewModel()
        #expect(vm.displayLabel(for: "1142") == "114-2")
        #expect(vm.displayLabel(for: "1131") == "113-1")
        #expect(vm.displayLabel(for: "X") == "X")
    }

    @Test func assignmentFilter_rawValuesArePersistableStrings() {
        #expect(AssignmentFilter.incomplete.rawValue == "未完成")
        #expect(AssignmentFilter.all.rawValue == "全部")
        #expect(AssignmentFilter(rawValue: "未完成") == .incomplete)
        #expect(AssignmentFilter(rawValue: "全部") == .all)
    }
}
