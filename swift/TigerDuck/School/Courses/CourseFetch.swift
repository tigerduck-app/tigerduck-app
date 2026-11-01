import Defaults
import Foundation
import os
import TigerDuckCore

enum CourseFetch {
    /// The Moodle and transcript answers every term of a warm-up shares, with the sign-in they
    /// were read for.
    struct TermAnswers: Sendable {
        let signIn: SignIn
        let moodle: [MoodleEnrolledCourse]?
        let transcript: ScoreReport?
    }

    static func fetchCourses(
        authService: AuthService,
        semester: String = CourseSelectionService.currentSemesterCode(),
        forceRefresh: Bool = false,
        resendingRoster: Bool = false,
        afterBackendPull: PullGate = { .completed },
        for signIn: SignIn
    ) async -> [SDCourse] {
        await fetchCourses(
            authService: authService,
            semester: semester,
            forceRefresh: forceRefresh,
            resendingRoster: resendingRoster,
            afterBackendPull: afterBackendPull,
            signIn: signIn,
            moodle: { await CourseSources.moodleCourses(for: signIn) },
            transcript: { await CourseSources.transcript(authService: authService, for: signIn) }
        )
    }

    static func handleLanguageChange() {
        NameAbbrService.shared.clearRawNameCache()
    }

    static func warmAllSemesterCaches(authService: AuthService, for signIn: SignIn) async {
        await SemesterCatalog.refreshIfStale()
        let semesters = SemesterCatalog.availableSemesters().filter {
            CourseStore.shared.loadCourses(semester: $0).isEmpty
        }
        await warmTerms(semesters) {
            TermAnswers(
                signIn: signIn,
                moodle: await CourseSources.moodleCourses(for: signIn),
                transcript: await CourseSources.transcript(authService: authService, for: signIn)
            )
        } fetch: { semester, answers in
            _ = await fetchCourses(
                authService: authService,
                semester: semester,
                forceRefresh: false,
                signIn: answers.signIn,
                moodle: { answers.moodle },
                transcript: { answers.transcript }
            )
        }
    }

    static func warmTerms(
        _ semesters: [String],
        shared: () async -> TermAnswers,
        fetch: @escaping @Sendable (_ semester: String, _ answers: TermAnswers) async -> Void
    ) async {
        guard !semesters.isEmpty else { return }
        let answers = await shared()
        guard answers.signIn.isCurrent else { return }
        await withTaskGroup(of: Void.self) { group in
            for semester in semesters {
                group.addTask { await fetch(semester, answers) }
            }
        }
    }

    private static func fetchCourses(
        authService: AuthService,
        semester: String,
        forceRefresh: Bool,
        resendingRoster: Bool = false,
        afterBackendPull: PullGate = { .completed },
        signIn: SignIn,
        moodle: () async -> [MoodleEnrolledCourse]?,
        transcript: () async -> ScoreReport?
    ) async -> [SDCourse] {
        await SemesterCatalog.refreshIfStale()
        // The course-selection system serves one term and its list has no term
        // marker, so its numbers belong to the term the catalogue reports open.
        let servesSelectionSemester = semester == SemesterCatalog.selectionSemesterCode()
        let display = CourseStore.shared.currentDisplay()
        let courseApiLanguage = display.language
        let editToken = CourseStore.shared.editToken

        guard !Task.isCancelled else { return [] }

        guard let studentId = authService.storedStudentId,
              let password = authService.storedPassword else {
            return CourseStore.shared.loadCourses(semester: semester)
        }

        let selection = servesSelectionSemester
            ? await CourseSources.selectionCourseNos(authService: authService, studentId: studentId, password: password,
                                                     semester: semester, forceRefresh: forceRefresh, for: signIn)
            : nil
        let courseSelectionNos = selection?.courseNos
        let selectionIsLive = selection?.live ?? false

        let selectionAnswered = courseSelectionNos?.isEmpty == false
        let report = selectionAnswered
            ? NTUSTScoreService.cachedScoreReport(studentId: studentId)?.report
            : await transcript()
        let scoreCoursesForSemester = report.map { TermRoster.classRows(of: $0, term: semester) }
        let cachedCourses = CourseStore.shared.loadCourses(semester: semester)
        let rebuilds = TermRoster.rebuildsFromTranscript(report, term: semester, servedBySelection: servesSelectionSemester)
        let term: TermRoster.TermCourseNos? = rebuilds
            ? TermRoster.TermCourseNos(
                courseNos: TermRoster.uniqueCourseNos(scoreCoursesForSemester?.map(\.code) ?? []), selectionRoster: nil
            )
            : TermRoster.termCourseNos(
                selection: courseSelectionNos,
                transcript: scoreCoursesForSemester?.map(\.code),
                cached: cachedCourses.map(\.courseNo)
            )
        guard let term else { return cachedCourses }

        let moodleAll = await moodle()
        // Numeric ids for `SDCourse.moodleDeepLink`: Moodle Mobile rejects `?idnumber=`.
        if let moodleAll, !Task.isCancelled {
            CourseLookup.replaceMoodleCourseIds(AssignmentRecords.moodleCourseIdMap(moodleAll), for: signIn)
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

        let looked = await concurrentMap(term.courseNos) { @MainActor courseNo -> (data: CourseData?, found: Bool) in
            var found = false
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
                found = !results.isEmpty
                return results
            }
            return (data, found)
        }.compactMap { item in
            item.data.map { TermRoster.LookedUpCourse(course: $0.course(in: semester), lookup: item.found ? .found : .fallback) }
        }

        guard await afterBackendPull() == .completed else { return CourseStore.shared.loadCourses(semester: semester) }
        if let roster = term.selectionRoster, !Task.isCancelled {
            CourseStore.shared.recordRoster(.courseSelection(roster), semester: semester, for: signIn)
            if selectionIsLive { CourseStore.shared.forgetServerDrops(listedIn: roster, semester: semester, for: signIn) }
        }

        let pastTerm = !rebuilds ? nil : TermRoster.rebuiltPastTerm(
            looked, unreadable: report.map { TermRoster.unreadableClassRows(of: $0, term: semester).map(\.code) } ?? [],
            cached: cachedCourses,
            others: Array(moodleByNo.keys) + (report?.courses.filter { $0.term == semester }.map(\.code) ?? []),
            userAdded: CourseStore.shared.loadUserAddedCourses().filter { CourseStore.userAddedCourse($0, belongsTo: semester) }
        )
        let drawn = pastTerm?.courses ?? TermRoster.drawnCourses(
            looked.map(\.course), fromSelection: term.selectionRoster != nil, cached: Set(cachedByNo.keys)
        )

        guard !Task.isCancelled, signIn.isCurrent else {
            return CourseStore.shared.loadCourses(semester: semester)
        }
        guard case .save(let courses) = TermRoster.savedCourses(
            drawn, pastTerm: pastTerm != nil, live: selectionIsLive && term.selectionRoster != nil,
            dropped: CourseStore.shared.loadServerDroppedNos(semester: semester)
        ) else { return cachedCourses }
        if let pastTerm {
            CourseStore.shared.recordRoster(
                .finalTranscript(pastTerm.roster, alsoListed: pastTerm.dropping), semester: semester, for: signIn
            )
        }
        guard CourseStore.shared.saveFetchedCourses(
            courses, semester: semester, display: display, since: editToken, for: signIn
        ) else {
            return CourseStore.shared.loadCourses(semester: semester)
        }
        CourseUpload.uploadVisibleCourses(
            courses, semester: semester, hidden: Set(CourseStore.shared.loadDeletedCourseNos()),
            roster: TermRoster.uploadedRoster(selection: term.selectionRoster, live: selectionIsLive, pastTerm: pastTerm?.roster),
            resendingRoster: resendingRoster, for: signIn, to: CourseUpload.courseUploader
        )
        return courses
    }

    static func record(
        _ status: ServerStatus,
        for server: ServerKind,
        note: String? = nil,
        round signIn: SignIn,
        tracker: ServerStatusTracker = .shared
    ) {
        guard signIn.isCurrent else { return }
        tracker.set(status, for: server, note: note)
    }
}
