import Defaults
import Foundation
import os
import TigerDuckCore

/// Fetches a term's courses from course selection, the transcript, Moodle and the course query,
/// and saves and uploads what it drew.
enum CourseFetch {

    typealias CourseUploader = (_ courses: [SDCourse], _ semester: String, _ asRoster: Bool, _ resend: Bool) -> Void

    static var courseUploader: CourseUploader?
    static var rosterRequests = RosterRequestLog()

    static func fetchCourses(
        authService: AuthService,
        semester: String = CourseSelectionService.currentSemesterCode(),
        forceRefresh: Bool = false,
        resendingRoster: Bool = false,
        applyAfter: @MainActor () async -> Void = {}
    ) async -> [SDCourse] {
        await fetchCourses(
            authService: authService,
            semester: semester,
            forceRefresh: forceRefresh,
            resendingRoster: resendingRoster,
            applyAfter: applyAfter,
            ticket: authService.session.ticket,
            moodle: { await fetchMoodleCourses(authService: authService) },
            transcript: { await fetchTranscript(authService: authService) }
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
            shared: { (await fetchMoodleCourses(authService: authService), await fetchTranscript(authService: authService)) }
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

    /// Hands every term the answers fetched once for all of them, with the sign-in they were
    /// fetched under: another account's answers must never pass a term's save check. Answers that
    /// outlive a sign-out are dropped.
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

    /// Nil lets a term fetch go on without Moodle, which only adds names and links.
    static func fetchMoodleCourses(authService: AuthService) async -> [MoodleEnrolledCourse]? {
        let ticket = authService.session.ticket
        do {
            let courses = try await MoodleEnrolledCoursesService.fetchEnrolled()
            record(.ok, for: .moodle, round: ticket, authService: authService)
            return courses
        } catch {
            record(.failed, for: .moodle, round: ticket, authService: authService)
            AppLogger.captureError(error, context: ["service": "fetchEnrolled", "flow": "classTable"])
            return nil
        }
    }

    /// A pull does not skip the day-long cache either, so a past term's refresh adds no
    /// score-system sign-in.
    static func fetchTranscript(authService: AuthService) async -> ScoreReport? {
        let ticket = authService.session.ticket
        guard let studentId = authService.storedStudentId,
              let password = authService.storedPassword else { return nil }
        do {
            #if DEBUG
            try await ServerFailureSimulator.shared.check(.scoreSystem)
            #endif
            let report = try await NTUSTScoreService.fetchScoreReport(
                session: NTUSTSessionManager.shared.session,
                studentId: studentId,
                password: password,
                persistGuard: { @Sendable [weak authService] in
                    authService?.session.isCurrent(ticket) == true
                }
            ).report
            record(.ok, for: .scoreSystem, round: ticket, authService: authService)
            return report
        } catch {
            record(.failed, for: .scoreSystem, round: ticket, authService: authService)
            AppLogger.captureError(error, context: ["service": "fetchScoreReport", "flow": "classTable"])
            return nil
        }
    }

    private static func fetchCourses(
        authService: AuthService,
        semester: String,
        forceRefresh: Bool,
        resendingRoster: Bool = false,
        applyAfter: @MainActor () async -> Void = {},
        ticket: AccountSession.Ticket,
        moodle: () async -> [MoodleEnrolledCourse]?,
        transcript: () async -> ScoreReport?
    ) async -> [SDCourse] {
        await SemesterCatalog.refreshIfStale()
        // The course-selection system serves one term and its list has no term
        // marker, so its numbers belong to the term the catalogue reports open.
        // `currentSemesterCode()` lags: its month heuristic would misfile them for weeks.
        let servesSelectionSemester = semester == SemesterCatalog.selectionSemesterCode()
        let display = CourseStore.shared.display()
        let courseApiLanguage = display.language
        let editToken = CourseStore.shared.editToken

        guard !Task.isCancelled else { return [] }

        guard let studentId = authService.storedStudentId,
              let password = authService.storedPassword else {
            return CourseStore.shared.loadCourses(semester: semester)
        }

        let session = NTUSTSessionManager.shared.session
        var courseSelectionNos: [String]?
        var selectionIsLive = false
        if servesSelectionSemester {
            do {
                #if DEBUG
                try await ServerFailureSimulator.shared.check(.courseSelection)
                #endif
                let answer = try await CourseSelectionService.fetchEnrolledCourseNos(
                    session: session,
                    studentId: studentId,
                    password: password,
                    forceRefresh: forceRefresh,
                    persistGuard: { @Sendable [weak authService] in
                        authService?.session.isCurrent(ticket) == true
                    }
                )
                courseSelectionNos = answer.courseNos
                selectionIsLive = answer.live
                await MainActor.run {
                    record(.ok, for: .courseSelection, round: ticket, authService: authService)
                }
            } catch {
                await MainActor.run {
                    record(.failed, for: .courseSelection, round: ticket, authService: authService)
                    AppLogger.captureError(error, context: [
                        "service": "fetchEnrolledCourseNos",
                        "semester": semester,
                        "fallback": "transcript",
                    ])
                }
            }
        }

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

        // The roster and the courses are applied once the backend's courses have been.
        await applyAfter()
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
        uploadVisibleCourses(
            courses, semester: semester, hidden: Set(CourseStore.shared.loadDeletedCourseNos()),
            roster: TermRoster.uploadedRoster(selection: term.roster, live: selectionIsLive, pastTerm: pastTerm?.roster),
            resendingRoster: resendingRoster, to: courseUploader
        )
        return courses
    }

    /// A requested term goes up even when unchanged: the backend asks because no roster of it
    /// arrived for a week.
    static func answerRosterRequests(in snapshot: [String: Any], authService: AuthService) {
        guard SyncPolicy.current.uploadsCourses else { return }
        for term in rosterRequests.termsToAsk(in: snapshot, signIn: authService.session.ticket, now: Date()) {
            AppLogger.sync.info("[sync] roster requested for \(term, privacy: .public)")
            Task {
                _ = await fetchCourses(authService: authService, semester: term, forceRefresh: true, resendingRoster: true)
            }
        }
    }

    /// Uploads the term's courses but those hidden here. They go as the term's roster when
    /// `roster`, course selection's answer or a past term's final transcript, names no course they
    /// leave out but a hidden one: the backend drops each school course a roster leaves out, so a
    /// failed lookup must not drop its course. A hidden course has no server row once its delete
    /// lands; listing it would file one for a course hidden before the server held it, and the
    /// next sync would show it again.
    static func uploadVisibleCourses(
        _ courses: [SDCourse],
        semester: String,
        hidden: Set<String>,
        roster: [String]? = nil,
        resendingRoster: Bool = false,
        to upload: CourseUploader?
    ) {
        let isHidden = { (courseNo: String) in CourseTombstone.isHidden(courseNo, semester: semester, in: hidden) }
        let visible = courses.filter { !isHidden($0.courseNo) }
        guard !visible.isEmpty else { return }
        let listed = Set(visible.map(\.courseNo))
        let asRoster = roster?.allSatisfy { listed.contains($0) || isHidden($0) } ?? false
        upload?(visible, semester, asRoster, resendingRoster && asRoster)
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
