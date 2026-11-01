import Defaults
import Foundation
import os
import TigerDuckCore

enum CourseFetch {


    static func fetchCourses(
        authService: AuthService,
        semester: String = CourseSelectionService.currentSemesterCode(),
        forceRefresh: Bool = false,
        resendingRoster: Bool = false,
        applyAfter: PullGate = { true }
    ) async -> [SDCourse] {
        await fetchCourses(
            authService: authService,
            semester: semester,
            forceRefresh: forceRefresh,
            resendingRoster: resendingRoster,
            applyAfter: applyAfter,
            ticket: authService.session.ticket,
            moodle: { await CourseSources.moodleCourses(authService: authService) },
            transcript: { await CourseSources.transcript(authService: authService) }
        )
    }

    static func handleLanguageChange() {
        NameAbbrService.shared.clearRawNameCache()
    }

    static func warmAllSemesterCaches(authService: AuthService) async {
        await SemesterCatalog.refreshIfStale()
        let semesters = SemesterCatalog.availableSemesters().filter {
            CourseStore.shared.loadCourses(semester: $0).isEmpty
        }
        await warmTerms(
            semesters,
            account: authService.session,
            shared: { (await CourseSources.moodleCourses(authService: authService), await CourseSources.transcript(authService: authService)) }
        ) { semester, ticket, moodle, transcript in
            _ = await fetchCourses(
                authService: authService,
                semester: semester,
                forceRefresh: false,
                ticket: ticket,
                moodle: { moodle },
                transcript: { transcript }
            )
        }
    }

    static func warmTerms(
        _ semesters: [String],
        account: AccountSession,
        shared: () async -> (moodle: [MoodleEnrolledCourse]?, transcript: ScoreReport?),
        fetch: @escaping @Sendable (
            _ semester: String, _ ticket: AccountSession.Ticket, _ moodle: [MoodleEnrolledCourse]?,
            _ transcript: ScoreReport?
        ) async -> Void
    ) async {
        guard !semesters.isEmpty else { return }
        let ticket = account.ticket
        let answers = await shared()
        guard account.isCurrent(ticket) else { return }
        await withTaskGroup(of: Void.self) { group in
            for semester in semesters {
                group.addTask { await fetch(semester, ticket, answers.moodle, answers.transcript) }
            }
        }
    }

    private static func fetchCourses(
        authService: AuthService,
        semester: String,
        forceRefresh: Bool,
        resendingRoster: Bool = false,
        applyAfter: PullGate = { true },
        ticket: AccountSession.Ticket,
        moodle: () async -> [MoodleEnrolledCourse]?,
        transcript: () async -> ScoreReport?
    ) async -> [SDCourse] {
        await SemesterCatalog.refreshIfStale()
        // The course-selection system serves one term and its list has no term
        // marker, so its numbers belong to the term the catalogue reports open.
        let servesSelectionSemester = semester == SemesterCatalog.selectionSemesterCode()
        let display = CourseStore.shared.display()
        let courseApiLanguage = display.language
        let editToken = CourseStore.shared.editToken

        guard !Task.isCancelled else { return [] }

        guard let studentId = authService.storedStudentId,
              let password = authService.storedPassword else {
            return CourseStore.shared.loadCourses(semester: semester)
        }

        let selection = servesSelectionSemester
            ? await CourseSources.selectionCourseNos(authService: authService, studentId: studentId, password: password,
                                                     semester: semester, forceRefresh: forceRefresh, ticket: ticket)
            : nil
        let courseSelectionNos = selection?.courseNos
        let selectionIsLive = selection?.live ?? false

        let selectionAnswered = courseSelectionNos?.isEmpty == false
        let report = selectionAnswered
            ? ScoreReportFiles.shared.loadScoreReport(studentId: studentId)?.report
            : await transcript()
        let scoreCoursesForSemester = report.map { TermRoster.classRows(of: $0, term: semester) }
        let cachedCourses = CourseStore.shared.loadCourses(semester: semester)
        let rebuilds = TermRoster.rebuildsFromTranscript(report, term: semester, servedBySelection: servesSelectionSemester)
        let term: (courseNos: [String], roster: [String]?)? = rebuilds
            ? (TermRoster.uniqueCourseNos(scoreCoursesForSemester?.map(\.code) ?? []), nil)
            : TermRoster.termCourseNos(
                selection: courseSelectionNos,
                transcript: scoreCoursesForSemester?.map(\.code),
                cached: cachedCourses.map(\.courseNo)
            )
        guard let term else { return cachedCourses }

        let moodleAll = await moodle()
        // Numeric ids for `SDCourse.moodleDeepLink`: Moodle Mobile rejects `?idnumber=`.
        if let moodleAll, !Task.isCancelled, authService.session.isCurrent(ticket) {
            MoodleFiles.shared.saveMoodleCourseIdMap(AssignmentRecords.moodleCourseIdMap(moodleAll))
        }

        let moodleByNo = Dictionary(
            (moodleAll ?? []).compactMap { course -> (String, MoodleEnrolledCourse)? in
                guard course.semester == semester, !course.courseNo.isEmpty else { return nil }
                return (course.courseNo, course)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let scoreByNo = Dictionary(
            (scoreCoursesForSemester ?? []).map { ($0.code, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let cachedByNo = Dictionary(
            cachedCourses.map { ($0.courseNo, CourseData($0)) },
            uniquingKeysWith: { first, _ in first }
        )

        let looked = await concurrentMap(term.courseNos) { @MainActor courseNo -> (data: CourseData?, answered: Bool) in
            var answered = false
            let data = await CourseDetails.refreshedCourseData(
                courseNo: courseNo,
                semester: semester,
                cached: cachedByNo[courseNo],
                moodle: moodleByNo[courseNo],
                grade: scoreByNo[courseNo],
                display: display
            ) {
                let results = try await CourseLookupService.lookupCourse(
                    semester: semester, courseNo: courseNo, language: courseApiLanguage,
                    fresh: forceRefresh
                )
                answered = !results.isEmpty
                return results
            }
            return (data, answered)
        }.compactMap { item in item.data.map { TermRoster.LookedUpCourse(course: $0.course(in: semester), answered: item.answered) } }

        guard await applyAfter() else { return CourseStore.shared.loadCourses(semester: semester) }
        if let roster = term.roster, !Task.isCancelled, authService.session.isCurrent(ticket) {
            CourseStore.shared.recordSelectionRoster(semester: semester, roster: roster)
            if selectionIsLive {
                let stillDropped = CourseStore.shared.loadServerDroppedNos(semester: semester).subtracting(roster)
                CourseStore.shared.saveServerDroppedNos(stillDropped, semester: semester)
            }
        }

        let pastTerm = !rebuilds ? nil : TermRoster.rebuiltPastTerm(
            looked, unreadable: report.map { TermRoster.unreadableClassRows(of: $0, term: semester).map(\.code) } ?? [],
            cached: cachedCourses,
            others: Array(moodleByNo.keys) + (report?.courses.filter { $0.term == semester }.map(\.code) ?? []),
            userAdded: CourseStore.shared.loadUserAddedCourses().filter { CourseStore.userAddedCourse($0, belongsTo: semester) }
        )
        let drawn = pastTerm?.courses ?? TermRoster.drawnCourses(
            looked.map(\.course), fromSelection: term.roster != nil, cached: Set(cachedByNo.keys)
        )

        guard !Task.isCancelled, authService.session.isCurrent(ticket) else {
            return CourseStore.shared.loadCourses(semester: semester)
        }
        guard let courses = TermRoster.savedCourses(
            drawn, pastTerm: pastTerm != nil, live: selectionIsLive && term.roster != nil,
            dropped: CourseStore.shared.loadServerDroppedNos(semester: semester)
        ) else { return cachedCourses }
        if let pastTerm {
            CourseStore.shared.recordSelectionRoster(
                semester: semester, roster: pastTerm.roster, alsoListed: pastTerm.dropping, isFinal: true
            )
        }
        guard CourseStore.shared.saveFetchedCourses(courses, semester: semester, display: display, since: editToken) else {
            return CourseStore.shared.loadCourses(semester: semester)
        }
        CourseUpload.uploadVisibleCourses(
            courses, semester: semester, hidden: Set(CourseStore.shared.loadDeletedCourseNos()),
            roster: TermRoster.uploadedRoster(selection: term.roster, live: selectionIsLive, pastTerm: pastTerm?.roster),
            resendingRoster: resendingRoster, to: CourseUpload.courseUploader
        )
        return courses
    }

    static func record(
        _ status: ServerStatus,
        for server: ServerKind,
        note: String? = nil,
        round ticket: AccountSession.Ticket,
        authService: AuthService,
        tracker: ServerStatusTracker = .shared
    ) {
        guard authService.session.isCurrent(ticket) else { return }
        tracker.set(status, for: server, note: note)
    }
}
