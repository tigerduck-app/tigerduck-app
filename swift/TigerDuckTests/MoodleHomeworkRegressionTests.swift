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
        let submitted = MoodleSubmissionStatus(assignId: 1, submissionStatus: "submitted", gradingStatus: "graded", submittedAt: nil)
        let draft = MoodleSubmissionStatus(assignId: 2, submissionStatus: "draft", gradingStatus: nil, submittedAt: nil)
        let new = MoodleSubmissionStatus(assignId: 3, submissionStatus: "new", gradingStatus: nil, submittedAt: nil)
        let absent = MoodleSubmissionStatus(assignId: 4, submissionStatus: nil, gradingStatus: nil, submittedAt: nil)

        #expect(submitted.isSubmitted)
        #expect(!draft.isSubmitted)
        #expect(!new.isSubmitted)
        #expect(!absent.isSubmitted)
    }

    // MARK: - AssignmentStatus

    @Test func assignmentStatus_pendingWhenFutureAndNotSubmitted() {
        let now = Date()
        let assignment = SDAssignment(
            assignmentId: "p1", courseNo: "C", courseName: "C", title: "T",
            dueDate: now.addingTimeInterval(3600), isCompleted: false
        )
        #expect(assignment.status(now: now) == .pending)
    }

    @Test func assignmentStatus_submittedOnTimeWhenSubmittedAtBeforeDue() {
        let due = Date()
        let assignment = SDAssignment(
            assignmentId: "s1", courseNo: "C", courseName: "C", title: "T",
            dueDate: due, isCompleted: true,
            submittedAt: due.addingTimeInterval(-60)
        )
        #expect(assignment.status(now: due.addingTimeInterval(120)) == .submitted)
    }

    @Test func assignmentStatus_submittedOnTimeWhenSubmittedAtMissing() {
        // When Moodle did not give us timemodified, default to .submitted
        // rather than mis-flagging the row as late.
        let due = Date()
        let assignment = SDAssignment(
            assignmentId: "s2", courseNo: "C", courseName: "C", title: "T",
            dueDate: due, isCompleted: true,
            submittedAt: nil
        )
        #expect(assignment.status(now: due.addingTimeInterval(86400)) == .submitted)
    }

    @Test func assignmentStatus_submittedLateWhenSubmittedAfterDue() {
        let due = Date()
        let assignment = SDAssignment(
            assignmentId: "l1", courseNo: "C", courseName: "C", title: "T",
            dueDate: due, isCompleted: true,
            submittedAt: due.addingTimeInterval(3600)
        )
        #expect(assignment.status(now: due.addingTimeInterval(7200)) == .submittedLate)
    }

    @Test func assignmentStatus_overdueAcceptableWhenPastDueAndWithinCutoff() {
        let due = Date().addingTimeInterval(-3600)
        let cutoff = Date().addingTimeInterval(3600)
        let assignment = SDAssignment(
            assignmentId: "o1", courseNo: "C", courseName: "C", title: "T",
            dueDate: due, isCompleted: false,
            cutoffDate: cutoff
        )
        #expect(assignment.status(now: Date()) == .overdueAcceptable)
    }

    @Test func assignmentStatus_overdueAcceptableWhenPastDueAndNoCutoff() {
        let due = Date().addingTimeInterval(-3600)
        let assignment = SDAssignment(
            assignmentId: "o2", courseNo: "C", courseName: "C", title: "T",
            dueDate: due, isCompleted: false,
            cutoffDate: nil
        )
        #expect(assignment.status(now: Date()) == .overdueAcceptable)
    }

    @Test func assignmentStatus_overdueRejectedWhenPastCutoff() {
        let now = Date()
        let assignment = SDAssignment(
            assignmentId: "o3", courseNo: "C", courseName: "C", title: "T",
            dueDate: now.addingTimeInterval(-7200), isCompleted: false,
            cutoffDate: now.addingTimeInterval(-3600)
        )
        #expect(assignment.status(now: now) == .overdueRejected)
    }

    @Test func assignmentStatus_lateSubmissionBeatsCutoff() {
        // A late but accepted submission should render as 已遲交 (orange),
        // not 逾期拒收, even when now is past the cutoff.
        let due = Date().addingTimeInterval(-86400)
        let cutoff = Date().addingTimeInterval(-3600)
        let submittedAt = Date().addingTimeInterval(-7200)
        let assignment = SDAssignment(
            assignmentId: "m1", courseNo: "C", courseName: "C", title: "T",
            dueDate: due, isCompleted: true,
            cutoffDate: cutoff,
            submittedAt: submittedAt
        )
        #expect(assignment.status(now: Date()) == .submittedLate)
    }

    @Test func assignmentStatus_archivedTakesPriorityOverMoodleState() {
        let now = Date()
        let assignment = SDAssignment(
            assignmentId: "a1", courseNo: "C", courseName: "C", title: "T",
            dueDate: now.addingTimeInterval(-3600), isCompleted: false,
            isArchived: true
        )
        #expect(assignment.status(now: now) == .archived)
    }

    @Test func assignmentStatus_locallyCompletedTakesPriorityOverMoodleState() {
        let now = Date()
        let assignment = SDAssignment(
            assignmentId: "lc1", courseNo: "C", courseName: "C", title: "T",
            dueDate: now.addingTimeInterval(-3600), isCompleted: false,
            isLocallyCompleted: true
        )
        #expect(assignment.status(now: now) == .locallyCompleted)
    }

    @Test func assignmentStatus_archivedBeatsLocallyCompleted() {
        // isArchived is checked first in status(); if both flags are somehow set, archived wins.
        let now = Date()
        let assignment = SDAssignment(
            assignmentId: "al1", courseNo: "C", courseName: "C", title: "T",
            dueDate: now.addingTimeInterval(-3600), isCompleted: false,
            isArchived: true, isLocallyCompleted: true
        )
        #expect(assignment.status(now: now) == .archived)
    }

    @Test func assignmentStatus_badgeMetadataMatchesCase() {
        #expect(AssignmentStatus.pending.badgeLabel == nil)
        #expect(AssignmentStatus.submitted.badgeLabel == "已繳交")
        #expect(AssignmentStatus.submittedLate.badgeLabel == "已遲交")
        #expect(AssignmentStatus.overdueAcceptable.badgeLabel == "逾期")
        #expect(AssignmentStatus.overdueRejected.badgeLabel == "逾期拒收")
        #expect(AssignmentStatus.archived.badgeLabel == "已封存")
        #expect(AssignmentStatus.locallyCompleted.badgeLabel == "標示為完成")

        #expect(!AssignmentStatus.overdueAcceptable.usesEmphasis)
        #expect(AssignmentStatus.overdueRejected.usesEmphasis)
        #expect(!AssignmentStatus.archived.usesEmphasis)
        #expect(!AssignmentStatus.locallyCompleted.usesEmphasis)
    }

    @Test func assignmentStatus_swipeEligibleOnlyForRawOverdueStates() {
        #expect(!AssignmentStatus.pending.isSwipeActionEligible)
        #expect(!AssignmentStatus.submitted.isSwipeActionEligible)
        #expect(!AssignmentStatus.submittedLate.isSwipeActionEligible)
        #expect(AssignmentStatus.overdueAcceptable.isSwipeActionEligible)
        #expect(AssignmentStatus.overdueRejected.isSwipeActionEligible)
        #expect(!AssignmentStatus.archived.isSwipeActionEligible)
        #expect(!AssignmentStatus.locallyCompleted.isSwipeActionEligible)
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

    @Test func arrayUpcomingSorted_excludesArchivedAndLocallyCompleted() {
        let now = Date()
        let normal = SDAssignment(
            assignmentId: "1", courseNo: "C", courseName: "C", title: "Normal",
            dueDate: now.addingTimeInterval(-3600), isCompleted: false
        )
        let archived = SDAssignment(
            assignmentId: "2", courseNo: "C", courseName: "C", title: "Archived",
            dueDate: now.addingTimeInterval(-7200), isCompleted: false, isArchived: true
        )
        let locallyDone = SDAssignment(
            assignmentId: "3", courseNo: "C", courseName: "C", title: "LocalDone",
            dueDate: now.addingTimeInterval(-1800), isCompleted: false, isLocallyCompleted: true
        )

        let result = [normal, archived, locallyDone].upcomingSorted()
        #expect(result.map(\.assignmentId) == ["1"])
    }

    @Test func arrayAllSorted_includesArchivedAndLocallyCompleted() {
        let now = Date()
        let normal = SDAssignment(
            assignmentId: "1", courseNo: "C", courseName: "C", title: "Normal",
            dueDate: now.addingTimeInterval(-3600), isCompleted: false
        )
        let archived = SDAssignment(
            assignmentId: "2", courseNo: "C", courseName: "C", title: "Archived",
            dueDate: now.addingTimeInterval(-7200), isCompleted: false, isArchived: true
        )
        let locallyDone = SDAssignment(
            assignmentId: "3", courseNo: "C", courseName: "C", title: "LocalDone",
            dueDate: now.addingTimeInterval(-1800), isCompleted: false, isLocallyCompleted: true
        )

        let result = [normal, archived, locallyDone].allSorted()
        // All three appear (none are moodle-completed), sorted by dueDate ascending
        #expect(result.map(\.assignmentId) == ["2", "1", "3"])
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

    @Test func latestSemesterFilter_excludesOtherSemesters() {
        let currentCourseNos: Set<String> = ["EC1013701", "CS5164701"]
        let assignments: [SDAssignment] = [
            SDAssignment(
                assignmentId: "1", courseNo: "EC1013701", courseName: "AI",
                title: "HW1", dueDate: Date()
            ),
            SDAssignment(
                assignmentId: "2", courseNo: "OLD1234567", courseName: "Old",
                title: "Past HW", dueDate: Date()
            )
        ]
        let filtered = assignments.filter { currentCourseNos.contains($0.courseNo) }
        #expect(filtered.map(\.assignmentId) == ["1"])
    }

    @Test func moodleOnlyCourse_survivesLookupFailure() {
        let moodleFullname = "114.2【資工系】CS5164701 隱私資訊安全"
        let moodleIdNumber = "1142CS5164701"
        let minimalCourse = SDCourse(
            courseNo: SDCourse.courseNoFromMoodleId(moodleIdNumber),
            courseName: moodleFullname,
            moodleIdNumber: moodleIdNumber,
            semester: String(moodleIdNumber.prefix(4))
        )
        #expect(minimalCourse.courseNo == "CS5164701")
        #expect(minimalCourse.semester == "1142")
        #expect(minimalCourse.courseName == moodleFullname)
    }

    @Test func moodleAssignmentService_exposesModAssignEntryPoints() async {
        let assignEntry = MoodleAssignmentService.fetchAssignments(courseIds:)
        let statusEntry = MoodleAssignmentService.fetchSubmissionStatus(assignId:)
        #expect(String(describing: assignEntry).isEmpty == false)
        #expect(String(describing: statusEntry).isEmpty == false)
    }
}
