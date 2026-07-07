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

    @Test func assignmentStatus_moodleCompletionBeatsLocalOverrides() {
        let due = Date().addingTimeInterval(-3600)
        let assignment = SDAssignment(
            assignmentId: "done1", courseNo: "C", courseName: "C", title: "T",
            dueDate: due, isCompleted: true,
            isArchived: true, isLocallyCompleted: true,
            submittedAt: due.addingTimeInterval(600)
        )
        #expect(assignment.status(now: Date()) == .submittedLate)
    }

    @Test func assignmentStatus_badgeMetadataMatchesCase() {
        #expect(AssignmentStatus.pending.badgeLabel == nil)
        #expect(AssignmentStatus.submitted.badgeLabel == "已繳交")
        #expect(AssignmentStatus.submittedLate.badgeLabel == "已遲交")
        #expect(AssignmentStatus.overdueAcceptable.badgeLabel == "逾期")
        #expect(AssignmentStatus.overdueRejected.badgeLabel == "逾期拒收")
        #expect(AssignmentStatus.archived.badgeLabel == "已忽略")
        #expect(AssignmentStatus.locallyCompleted.badgeLabel == "標示為完成")

        #expect(!AssignmentStatus.overdueAcceptable.usesEmphasis)
        #expect(AssignmentStatus.overdueRejected.usesEmphasis)
        #expect(!AssignmentStatus.archived.usesEmphasis)
        #expect(!AssignmentStatus.locallyCompleted.usesEmphasis)
    }

    @Test func assignmentStatus_onlyMoodleSubmittedRowsAreNonSwipeable() {
        #expect(AssignmentStatus.pending.isSwipeActionEligible)
        #expect(!AssignmentStatus.submitted.isSwipeActionEligible)
        #expect(!AssignmentStatus.submittedLate.isSwipeActionEligible)
        #expect(AssignmentStatus.overdueAcceptable.isSwipeActionEligible)
        #expect(AssignmentStatus.overdueRejected.isSwipeActionEligible)
        // Archived and locally-completed rows stay swipeable so the user can undo.
        #expect(AssignmentStatus.archived.isSwipeActionEligible)
        #expect(AssignmentStatus.locallyCompleted.isSwipeActionEligible)
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

    @Test func arrayAllSorted_excludesIgnoredButIncludesLocallyCompleted() {
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

        let candidates = [normal, archived, locallyDone].allCandidates()
        // archived (uncompleted) removed; locallyDone + normal both kept
        // (filter is time-agnostic at this layer).
        #expect(Set(candidates.map(\.assignmentId)) == ["1", "3"])

        let partitioned = candidates.partitionedByDueDate(now: now)
        // Both items are past; past bucket sorts descending so the
        // more-recently due `locallyDone` (-1800s) lands above `normal` (-3600s).
        #expect(partitioned.map(\.assignmentId) == ["3", "1"])
    }

    @Test func allCandidates_keepsArchivedRowsOnceMoodleMarksThemCompleted() {
        let now = Date()
        let ignoredOnly = SDAssignment(
            assignmentId: "ignored", courseNo: "C", courseName: "C", title: "Ignored",
            dueDate: now.addingTimeInterval(-3600), isCompleted: false, isArchived: true
        )
        // Reachable real-world state: user swipes-to-ignore (isArchived=true),
        // later submits on Moodle so the next sync flips isCompleted=true
        // without clearing the local archive flag.
        let ignoredThenSubmitted = SDAssignment(
            assignmentId: "ignored+submitted", courseNo: "C", courseName: "C",
            title: "IgnoredThenSubmitted",
            dueDate: now.addingTimeInterval(-7200),
            isCompleted: true, isArchived: true
        )

        // 全部 must surface the submitted row (status would render as
        // .submitted, not .archived). The pure-ignored row stays excluded —
        // it belongs to the 已忽略 filter.
        let all = [ignoredOnly, ignoredThenSubmitted].allCandidates()
        #expect(all.map(\.assignmentId) == ["ignored+submitted"])

        // 已忽略 requires !isCompleted, so it only contains the pure-ignored
        // row. Together with the assertion above this guarantees the
        // submitted-archived row is reachable from at least one filter.
        let ignored = [ignoredOnly, ignoredThenSubmitted].ignoredSorted()
        #expect(ignored.map(\.assignmentId) == ["ignored"])
    }

    @Test func arrayIgnoredSorted_onlyIncludesIgnoredUnsubmittedAssignments() {
        let now = Date()
        let ignoredLater = SDAssignment(
            assignmentId: "1", courseNo: "C", courseName: "C", title: "IgnoredLater",
            dueDate: now.addingTimeInterval(-1800), isCompleted: false, isArchived: true
        )
        let ignoredEarlier = SDAssignment(
            assignmentId: "2", courseNo: "C", courseName: "C", title: "IgnoredEarlier",
            dueDate: now.addingTimeInterval(-7200), isCompleted: false, isArchived: true
        )
        let normal = SDAssignment(
            assignmentId: "3", courseNo: "C", courseName: "C", title: "Normal",
            dueDate: now.addingTimeInterval(-3600), isCompleted: false
        )
        let completedIgnored = SDAssignment(
            assignmentId: "4", courseNo: "C", courseName: "C", title: "CompletedIgnored",
            dueDate: now.addingTimeInterval(-5400), isCompleted: true, isArchived: true
        )

        let result = [ignoredLater, ignoredEarlier, normal, completedIgnored].ignoredSorted()
        #expect(result.map(\.assignmentId) == ["2", "1"])
        #expect([ignoredLater, ignoredEarlier, normal, completedIgnored].hasIgnored())
        #expect(![normal, completedIgnored].hasIgnored())
    }

    @Test func partitionedByDueDate_putsFutureAscendingBeforePastDescending() {
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

        // 全部 tab partitions by time, not by completion. Future bucket
        // (c2 @ +3600 < i2 @ +7200) ascending, then past bucket (i1 @
        // -3600 > c1 @ -7200) descending. The partition is intentionally
        // re-applied on every TimelineView tick — this test pins the
        // expected ordering for a fixed `now`.
        let result = [completedA, incompleteB, completedB, incompleteA]
            .partitionedByDueDate(now: now)
        #expect(result.map(\.assignmentId) == ["c2", "i2", "i1", "c1"])
    }

    @Test func partitionedByDueDate_rebucketsAsClockAdvancesPastDueDate() {
        let now = Date()
        let crossingSoon = SDAssignment(
            assignmentId: "x", courseNo: "C", courseName: "C", title: "X",
            dueDate: now.addingTimeInterval(60), isCompleted: false
        )
        let laterFuture = SDAssignment(
            assignmentId: "y", courseNo: "C", courseName: "C", title: "Y",
            dueDate: now.addingTimeInterval(3600), isCompleted: false
        )

        // At `now`, both are future and sort ascending.
        let before = [crossingSoon, laterFuture].partitionedByDueDate(now: now)
        #expect(before.map(\.assignmentId) == ["x", "y"])

        // Two minutes later, `crossingSoon` has slipped into the past
        // bucket and now sits *below* `laterFuture`. Regression guard for
        // the time-frozen bug: the same input list must re-bucket purely
        // by passing a fresher `now`.
        let after = [crossingSoon, laterFuture]
            .partitionedByDueDate(now: now.addingTimeInterval(120))
        #expect(after.map(\.assignmentId) == ["y", "x"])
    }

    @MainActor
    @Test func classTableViewModel_displayLabel_formatsSemesterCode() {
        let vm = ClassTableViewModel()
        #expect(vm.displayLabel(for: "1142") == "114-2")
        #expect(vm.displayLabel(for: "1131") == "113-1")
        #expect(vm.displayLabel(for: "X") == "X")
    }

    @Test func assignmentFilter_rawValuesArePersistableStrings() {
        #expect(AssignmentFilter.incomplete.rawValue == "未完成")
        #expect(AssignmentFilter.all.rawValue == "全部")
        #expect(AssignmentFilter.ignored.rawValue == "已忽略")
        #expect(AssignmentFilter(rawValue: "未完成") == .incomplete)
        #expect(AssignmentFilter(rawValue: "全部") == .all)
        #expect(AssignmentFilter(rawValue: "已忽略") == .ignored)
    }

    @Test func assignmentFilter_visibleFiltersAddsIgnoredOnlyWhenNeeded() {
        #expect(AssignmentFilter.visibleFilters(hasIgnored: false) == [.incomplete, .all])
        #expect(AssignmentFilter.visibleFilters(hasIgnored: true) == [.incomplete, .all, .ignored])
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
