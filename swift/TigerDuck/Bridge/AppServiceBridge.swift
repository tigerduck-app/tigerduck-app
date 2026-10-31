import Foundation
import Defaults
import os
import TigerDuckCore

struct CourseData: Sendable {
    let courseNo: String
    var courseName: String
    let instructor: String
    let credits: Double
    var classroom: String
    let enrolledCount: Int
    let maxCount: Int
    let schedule: [Int: [String]]
    let moodleIdNumber: String?
    var classroomMap: [String: String]
    let dimension: String
    let allYear: String
    let requireOption: String
}

enum AppServiceBridge {

    typealias CourseUploader = (_ courses: [SDCourse], _ semester: String, _ asRoster: Bool, _ resend: Bool) -> Void

    static var courseUploader: CourseUploader?
    static var assignmentUploader: ((PushAPI.AssignmentUploadRequest) -> Void)?
    static var rosterRequests = RosterRequestLog()

    static func fetchCourses(
        authService: AuthService,
        semester: String = CourseSelectionService.currentSemesterCode(),
        forceRefresh: Bool = false,
        resendingRoster: Bool = false
    ) async -> [SDCourse] {
        await fetchCourses(
            authService: authService,
            semester: semester,
            forceRefresh: forceRefresh,
            resendingRoster: resendingRoster,
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
        let scoreCoursesForSemester = report.map { classRows(of: $0, term: semester) }
        let cachedCourses = CourseStore.shared.loadCourses(semester: semester)
        let rebuilds = rebuildsFromTranscript(report, term: semester, servedBySelection: servesSelectionSemester)
        let term: (courseNos: [String], roster: [String]?)? = rebuilds
            ? (uniqueCourseNos(scoreCoursesForSemester?.map(\.code) ?? []), nil)
            : termCourseNos(
                selection: courseSelectionNos,
                transcript: scoreCoursesForSemester?.map(\.code),
                cached: cachedCourses.map(\.courseNo)
            )
        guard let term else { return cachedCourses }
        if let roster = term.roster, !Task.isCancelled, authService.session.isCurrent(ticket) {
            CourseStore.shared.recordSelectionRoster(semester: semester, roster: roster)
            if selectionIsLive {
                let stillDropped = CourseStore.shared.loadServerDroppedNos(semester: semester).subtracting(roster)
                CourseStore.shared.saveServerDroppedNos(stillDropped, semester: semester)
            }
        }

        let moodleAll = await moodle()
        // Numeric ids for `SDCourse.moodleDeepLink`: Moodle Mobile rejects `?idnumber=`.
        if let moodleAll, !Task.isCancelled, authService.session.isCurrent(ticket) {
            MoodleFiles.shared.saveMoodleCourseIdMap(moodleCourseIdMap(moodleAll))
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
            let data = await refreshedCourseData(
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
        }.compactMap { item in item.data.map { LookedUpCourse(course: $0.course(in: semester), answered: item.answered) } }

        let pastTerm = !rebuilds ? nil : rebuiltPastTerm(
            looked, unreadable: report.map { unreadableClassRows(of: $0, term: semester).map(\.code) } ?? [],
            cached: cachedCourses,
            others: Array(moodleByNo.keys) + (report?.courses.filter { $0.term == semester }.map(\.code) ?? []),
            userAdded: CourseStore.shared.loadUserAddedCourses().filter { CourseStore.userAddedCourse($0, belongsTo: semester) }
        )
        let drawn = pastTerm?.courses ?? drawnCourses(
            looked.map(\.course), fromSelection: term.roster != nil, cached: Set(cachedByNo.keys)
        )

        guard !Task.isCancelled, authService.session.isCurrent(ticket) else {
            return CourseStore.shared.loadCourses(semester: semester)
        }
        guard let courses = savedCourses(
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
            roster: uploadedRoster(selection: term.roster, live: selectionIsLive, pastTerm: pastTerm?.roster),
            resendingRoster: resendingRoster, to: courseUploader
        )
        return courses
    }

    /// A requested term goes up even when unchanged: the backend asks because no roster of it
    /// arrived for a week.
    static func answerRosterRequests(in snapshot: [String: Any], authService: AuthService) {
        guard CourseUploadPolicy.uploadsCourses else { return }
        for term in rosterRequests.termsToAsk(in: snapshot, signIn: authService.session.ticket, now: Date()) {
            AppLogger.sync.info("[sync] roster requested for \(term, privacy: .public)")
            Task {
                _ = await fetchCourses(authService: authService, semester: term, forceRefresh: true, resendingRoster: true)
            }
        }
    }

    /// The courses a fetch saves, or nil when it drew none and the term keeps its cache. Those
    /// dropped on the server are read as it saves: a full sync during its lookups may drop one a
    /// cached course selection answer or the transcript still lists, and a fetch whose every
    /// course was dropped saves none. Only a live answer or a past term's final transcript brings
    /// one back.
    static func savedCourses(_ drawn: [SDCourse], pastTerm: Bool, live: Bool, dropped: Set<String>) -> [SDCourse]? {
        guard !drawn.isEmpty || pastTerm else { return nil }
        return pastTerm || live ? drawn : drawn.filter { !dropped.contains($0.courseNo) }
    }

    /// The roster a fetch uploads: a past term's final transcript, or course selection's answer
    /// only when this fetch got it from the school. One cached for up to a day may still name a
    /// course another device's roster dropped since, and would enroll it again.
    static func uploadedRoster(selection: [String]?, live: Bool, pastTerm: [String]?) -> [String]? {
        pastTerm ?? (live ? selection : nil)
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

    /// A term's course numbers, or nil when no source answers and the term keeps its cached
    /// courses. Course selection's answer owns the term it serves and is the roster its drops are
    /// read from. Any other term, or that one when course selection gives nothing, adds the
    /// transcript's classes to its cached courses: a transcript lists a running term late or in
    /// part, so it never removes one. Moodle lists course sites and keeps a dropped class, so it
    /// adds none. An empty list counts as nil: the D01 regex scrape returns no matches, not an
    /// error, when the page drifts.
    static func termCourseNos(
        selection: [String]?, transcript: [String]?, cached: [String]
    ) -> (courseNos: [String], roster: [String]?)? {
        let fromSelection = uniqueCourseNos(selection ?? [])
        if !fromSelection.isEmpty { return (fromSelection, fromSelection) }
        let fromTranscript = uniqueCourseNos(transcript ?? [])
        guard !fromTranscript.isEmpty else { return nil }
        return (uniqueCourseNos(fromTranscript + cached), nil)
    }

    struct LookedUpCourse {
        let course: SDCourse
        /// Whether the course query found the course; when it did not, `course` is the cached copy
        /// or one built from Moodle and the transcript.
        let answered: Bool
    }

    /// A past term rebuilt from the transcript: its classes the course query found with class
    /// times, and the cached copy of one it did not find or of an `unreadable` row it cannot look
    /// up, as neither removes a course. `roster` names those and the classes still waiting for a
    /// lookup. Every other course the term may hold here or on the server, cached, merged from the
    /// server, a Moodle site or a row the rule leaves out in `others`, is in `dropping`, so its
    /// server row is not merged back. A course added by hand is never dropped.
    static func rebuiltPastTerm(
        _ looked: [LookedUpCourse], unreadable: [String], cached: [SDCourse], others: [String], userAdded: [SDCourse]
    ) -> (courses: [SDCourse], roster: [String], dropping: [String]) {
        let hasTimes = { (course: SDCourse) in course.schedule.values.contains { !$0.isEmpty } }
        let cachedNos = Set(cached.map(\.courseNo))
        let courses = looked.filter { $0.answered ? hasTimes($0.course) : cachedNos.contains($0.course.courseNo) }
            .map(\.course) + cached.filter { unreadable.contains($0.courseNo) }
        let roster = looked.filter { !$0.answered || hasTimes($0.course) }.map(\.course.courseNo) + unreadable
        let addedHere = Set(userAdded.filter { $0.moodleIdNumber == nil }.map(\.courseNo))
        let merged = userAdded.filter { $0.moodleIdNumber != nil }.map(\.courseNo)
        let dropping = (Array(cachedNos) + merged + others).filter { !addedHere.contains($0) }
        return (courses, roster, dropping)
    }

    /// A term the transcript lists is rebuilt only once it lists a later one too: then the term
    /// has ended and the transcript holds all of it, even when that leaves no class to draw. The
    /// newest term listed may still run or miss grades, and the term course selection serves is
    /// its own, so both only add. An exempted row can be filed under any term and counts for neither.
    static func rebuildsFromTranscript(_ report: ScoreReport?, term: String, servedBySelection: Bool) -> Bool {
        guard !servedBySelection, let report else { return false }
        let listed = report.courses.filter { $0.status != .exempted }
        guard listed.contains(where: { $0.term == term }), let current = AcademicTerm(code: term) else { return false }
        return listed.contains { AcademicTerm(code: $0.term).map { $0 > current } ?? false }
    }

    /// A class the transcript adds joins its term only with class times: a row without them, or one
    /// whose lookup failed, has nothing to draw, and a later fetch adds it once the lookup answers.
    /// Course selection's courses and the term's cached ones stay as they are.
    static func drawnCourses(_ courses: [SDCourse], fromSelection: Bool, cached: Set<String>) -> [SDCourse] {
        guard !fromSelection else { return courses }
        return courses.filter { cached.contains($0.courseNo) || $0.schedule.values.contains { !$0.isEmpty } }
    }

    private static func uniqueCourseNos(_ courseNos: [String]) -> [String] {
        var seen = Set<String>()
        return courseNos.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The term's transcript rows that stand for a class. Withdrawn and exempted rows and the
    /// school English proficiency test have none to draw. Codes are read with
    /// `CourseSelectionService.isCourseNo`, which takes NTU and NTNU courses too.
    static func classRows(of report: ScoreReport, term: String) -> [CourseGrade] {
        ruleRows(of: report, term: term).filter { CourseSelectionService.isCourseNo($0.code[...]) }
    }

    /// The rows the rule keeps whose code is no course number, so the course query cannot look
    /// them up.
    static func unreadableClassRows(of report: ScoreReport, term: String) -> [CourseGrade] {
        ruleRows(of: report, term: term).filter { !$0.code.isEmpty && !CourseSelectionService.isCourseNo($0.code[...]) }
    }

    private static func ruleRows(of report: ScoreReport, term: String) -> [CourseGrade] {
        report.courses.filter {
            $0.term == term && $0.status != .withdrew && $0.status != .exempted && !isEnglishProficiencyTest($0)
        }
    }

    /// The school English proficiency test, a graduation requirement the transcript files as a
    /// course row, under its own course number or, should that change, its exact name.
    static func isEnglishProficiencyTest(_ row: CourseGrade) -> Bool {
        row.code == "CC1011301" || row.name.trimmingCharacters(in: .whitespacesAndNewlines) == "校定英文能力檢測"
    }

    static func moodleCourseIdMap(_ courses: [MoodleEnrolledCourse]) -> [String: Int] {
        var map: [String: Int] = [:]
        for course in courses {
            for alias in course.idnumbers.dropFirst() {
                let key = SDCourse.normalizedMoodleId(alias)
                if map[key] == nil { map[key] = course.id }
            }
        }
        for course in courses where !course.idnumber.isEmpty {
            map[SDCourse.normalizedMoodleId(course.idnumber)] = course.id
        }
        return map
    }

    /// School requests a fetch has in flight at once. Past the per-host connection limit they
    /// queue, and each one's timeout runs while it waits.
    nonisolated static let maxConcurrentRequests = 4

    static func concurrentMap<Item: Sendable, Output: Sendable>(
        _ items: [Item],
        limit: Int = maxConcurrentRequests,
        _ transform: @escaping @Sendable (Item) async -> Output
    ) async -> [Output] {
        await withTaskGroup(of: (Int, Output).self) { group in
            var results = [Output?](repeating: nil, count: items.count)
            for (index, item) in items.enumerated() {
                if index >= limit, let (finished, output) = await group.next() {
                    results[finished] = output
                }
                group.addTask { (index, await transform(item)) }
            }
            for await (finished, output) in group {
                results[finished] = output
            }
            return results.compactMap { $0 }
        }
    }

    static func assignmentCourseNo(
        for course: MoodleEnrolledCourse,
        localCourseNos: Set<String>
    ) -> String {
        course.courseNos.first(where: localCourseNos.contains) ?? course.courseNo
    }

    static func selectionDrops(
        previous: Set<String>,
        localPortalNos: [String],
        roster: [String],
        isFinal: Bool = false
    ) -> Set<String> {
        guard !roster.isEmpty || isFinal else { return previous }
        let enrolled = Set(roster)
        return previous.union(localPortalNos).subtracting(enrolled)
    }

    struct CourseDisplayPreferences: Equatable, Sendable {
        let language: String
        let courseAbbrEnabled: Bool
        let classroomAbbrEnabled: Bool
        let classroomMandarinDisplay: String

        static func current() -> CourseDisplayPreferences {
            CourseDisplayPreferences(
                language: LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage]),
                courseAbbrEnabled: Defaults[.useEnglishCourseAbbreviation],
                classroomAbbrEnabled: Defaults[.useEnglishClassroomAbbreviation],
                classroomMandarinDisplay: Defaults[.classroomMandarinDisplay]
            )
        }
    }

    static func refreshedCourseData(
        courseNo: String,
        semester: String,
        cached: CourseData?,
        moodle: MoodleEnrolledCourse?,
        grade: CourseGrade?,
        display: CourseDisplayPreferences,
        lookup: () async throws -> [CourseSearchResult]
    ) async -> CourseData? {
        do {
            let results = try await lookup()
            guard !results.isEmpty else {
                return cached ?? fallbackCourseData(courseNo: courseNo, moodle: moodle, grade: grade)
            }
            return enrichedCourseData(
                from: results,
                semester: semester,
                fallbackMoodleIdNumber: moodle?.idnumber,
                display: display
            )
        } catch {
            AppLogger.captureError(error, context: [
                "service": "courseLookup",
                "semester": semester,
                "courseNo": courseNo,
            ])
            return cached ?? fallbackCourseData(courseNo: courseNo, moodle: moodle, grade: grade)
        }
    }

    static func importedCourses(semester: String, courseNos: [String]) async throws -> [SDCourse] {
        let display = CourseDisplayPreferences.current()
        return try await importedCourses(semester: semester, courseNos: courseNos, display: display) { courseNo in
            try await CourseLookupService.lookupCourse(
                semester: semester, courseNo: courseNo, language: display.language
            )
        }
    }

    static func importedCourses(
        semester: String,
        courseNos: [String],
        display: CourseDisplayPreferences,
        lookup: @escaping @MainActor @Sendable (_ courseNo: String) async throws -> [CourseSearchResult]
    ) async throws -> [SDCourse] {
        let answers = await concurrentMap(courseNos) { @MainActor courseNo -> Result<CourseData?, any Error> in
            do {
                let results = try await lookup(courseNo)
                guard !results.isEmpty else { return .success(nil) }
                return .success(enrichedCourseData(
                    from: results, semester: semester, fallbackMoodleIdNumber: nil, display: display,
                    recordsRawLabels: false
                ))
            } catch {
                return .failure(error)
            }
        }
        return try answers.compactMap { try $0.get() }.map { $0.course(in: semester) }
    }

    private static func enrichedCourseData(
        from results: [CourseSearchResult],
        semester: String,
        fallbackMoodleIdNumber: String?,
        display: CourseDisplayPreferences,
        recordsRawLabels: Bool = true
    ) -> CourseData {
        let course = buildSDCourse(
            from: results,
            semester: semester,
            fallbackMoodleIdNumber: fallbackMoodleIdNumber
        )
        var data = CourseData(
            courseNo: course.courseNo,
            courseName: course.courseName,
            instructor: course.instructor,
            credits: course.credits,
            classroom: course.classroom,
            enrolledCount: course.enrolledCount,
            maxCount: course.maxCount,
            schedule: course.schedule,
            moodleIdNumber: course.moodleIdNumber,
            classroomMap: course.classroomMap,
            dimension: course.dimension,
            allYear: course.allYear,
            requireOption: course.requireOption
        )
        if recordsRawLabels {
            NameAbbrService.shared.storeRawName(courseNo: data.courseNo, name: data.courseName)
            NameAbbrService.shared.storeRawClassroom(
                courseNo: data.courseNo, classroom: data.classroom, map: data.classroomMap
            )
        }
        if display.language == "en" && display.courseAbbrEnabled {
            data.courseName = NameAbbrService.shared.abbreviateName(data.courseName)
        }
        if display.classroomAbbrEnabled || display.classroomMandarinDisplay != "original" {
            data.classroom = NameAbbrService.shared.abbreviateClassroom(
                data.classroom, display: display.classroomMandarinDisplay
            )
            data.classroomMap = data.classroomMap.mapValues {
                NameAbbrService.shared.abbreviateClassroom($0, display: display.classroomMandarinDisplay)
            }
        }
        return data
    }

    static func refreshUserAddedCourses(
        semester: String, authService: AuthService, courses: CourseStore = .shared,
        lookup: @escaping @MainActor @Sendable (_ semester: String, _ courseNo: String, _ language: String, _ fresh: Bool) async throws -> [CourseSearchResult] = {
            try await CourseLookupService.lookupCourse(semester: $0, courseNo: $1, language: $2, fresh: $3)
        }
    ) async -> [SDCourse] {
        let ticket = authService.session.ticket
        let targets = courses.loadUserAddedCourses(semester: semester)
        guard !targets.isEmpty else { return [] }
        let display = courses.display()
        let seeds = targets.map { ($0.courseNo, $0.moodleIdNumber, $0.semester.isEmpty ? semester : $0.semester) }

        let lookups = await concurrentMap(seeds) { @MainActor seed -> (String, CourseData)? in
            let (courseNo, moodleId, rowSemester) = seed
            guard let results = try? await lookup(rowSemester, courseNo, display.language, true),
                  !results.isEmpty else { return nil }
            return (courseNo, enrichedCourseData(
                from: results, semester: rowSemester,
                fallbackMoodleIdNumber: moodleId, display: display
            ))
        }
        let refreshed = Dictionary(lookups.compactMap { $0 }, uniquingKeysWith: { _, last in last })
        guard authService.session.isCurrent(ticket) else { return [] }
        courses.applyLookedUp(refreshed, semester: semester, enrolled: false, display: display)
        return courses.loadUserAddedCourses(semester: semester)
    }

    static func refreshImportedCourses(semester: String, courseNos: [String], current: [SDCourse]) async -> [SDCourse]? {
        guard await NetworkMonitor.shared.isReachable() else { return nil }
        let display = CourseDisplayPreferences.current()
        return await refreshImportedCourses(
            semester: semester, courseNos: courseNos, current: current, display: display
        ) { courseNo in
            try await CourseLookupService.lookupCourse(
                semester: semester, courseNo: courseNo, language: display.language, fresh: true
            )
        }
    }

    static func refreshImportedCourses(
        semester: String,
        courseNos: [String],
        current: [SDCourse],
        display: CourseDisplayPreferences,
        lookup: @escaping @MainActor @Sendable (_ courseNo: String) async throws -> [CourseSearchResult]
    ) async -> [SDCourse]? {
        let cachedByNo = Dictionary(
            current.map { ($0.courseNo, CourseData($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let answers = await concurrentMap(courseNos) { @MainActor courseNo -> (data: CourseData?, failed: Bool) in
            do {
                let results = try await lookup(courseNo)
                guard !results.isEmpty else { return (cachedByNo[courseNo], false) }
                let data = enrichedCourseData(
                    from: results, semester: semester, fallbackMoodleIdNumber: nil, display: display,
                    recordsRawLabels: false
                )
                return (data, false)
            } catch {
                AppLogger.captureError(error, context: [
                    "service": "courseLookup", "flow": "importedClassTable", "semester": semester,
                ])
                return (cachedByNo[courseNo], true)
            }
        }
        guard answers.contains(where: { !$0.failed }) else { return nil }
        return answers.compactMap { $0.data?.course(in: semester) }
    }

    static func refreshCoursesMissingClassroom(
        semester: String, authService: AuthService, courses: CourseStore = .shared,
        lookup: @escaping @MainActor @Sendable (_ semester: String, _ courseNo: String, _ language: String, _ fresh: Bool) async throws -> [CourseSearchResult] = {
            try await CourseLookupService.lookupCourse(semester: $0, courseNo: $1, language: $2, fresh: $3)
        }
    ) async -> Bool {
        let ticket = authService.session.ticket
        let seeds = (courses.loadCourses(semester: semester) + courses.loadUserAddedCourses(semester: semester))
            .filter { $0.classroom.isEmpty }
            .map { ($0.courseNo, $0.moodleIdNumber) }
        guard !seeds.isEmpty else { return false }
        let display = courses.display()

        let lookups = await concurrentMap(seeds) { @MainActor seed -> (String, CourseData)? in
            let (courseNo, moodleId) = seed
            guard let results = try? await lookup(semester, courseNo, display.language, false),
                  !results.isEmpty else { return nil }
            let data = enrichedCourseData(
                from: results, semester: semester,
                fallbackMoodleIdNumber: moodleId, display: display
            )
            return data.classroom.isEmpty ? nil : (courseNo, data)
        }
        let found = Dictionary(lookups.compactMap { $0 }, uniquingKeysWith: { _, last in last })
        guard authService.session.isCurrent(ticket) else { return false }
        return courses.applyLookedUp(found, semester: semester, enrolled: true, display: display)
    }

    nonisolated private static func fallbackCourseData(
        courseNo: String,
        moodle: MoodleEnrolledCourse?,
        grade: CourseGrade?
    ) -> CourseData? {
        if let moodle {
            return CourseData(
                courseNo: courseNo,
                courseName: moodle.fullname,
                instructor: "",
                credits: grade?.credits ?? 0,
                classroom: "",
                enrolledCount: 0,
                maxCount: 0,
                schedule: [:],
                moodleIdNumber: moodle.idnumber,
                classroomMap: [:],
                dimension: "",
                allYear: "",
                requireOption: ""
            )
        }
        if let grade {
            return CourseData(
                courseNo: courseNo,
                courseName: grade.name,
                instructor: "",
                credits: grade.credits ?? 0,
                classroom: "",
                enrolledCount: 0,
                maxCount: 0,
                schedule: [:],
                moodleIdNumber: nil,
                classroomMap: [:],
                dimension: "",
                allYear: "",
                requireOption: ""
            )
        }
        return nil
    }

    nonisolated private static func buildSDCourse(
        from results: [CourseSearchResult],
        semester: String,
        fallbackMoodleIdNumber: String?
    ) -> SDCourse {
        let first = results[0]

        var mergedSchedule: [Int: [String]] = [:]
        var classroomMap: [String: String] = [:]
        var allClassrooms: [String] = []
        var seenClassrooms = Set<String>()

        for row in results {
            let partial = CourseLookupService.parseNodeToSchedule(row.Node)
            var seenParts = Set<String>()
            let uniqueParts = SDCourse.splitRoom(row.ClassRoomNo ?? "")
                .filter { seenParts.insert($0).inserted }
            let room = uniqueParts.joined(separator: ", ")

            for (day, periods) in partial {
                mergedSchedule[day, default: []].append(contentsOf: periods)
                if !room.isEmpty {
                    for period in periods {
                        classroomMap["\(day)-\(period)"] = room
                    }
                }
            }

            for part in uniqueParts where !seenClassrooms.contains(part) {
                seenClassrooms.insert(part)
                allClassrooms.append(part)
            }
        }

        return SDCourse(
            courseNo: first.CourseNo,
            courseName: first.CourseName,
            instructor: first.CourseTeacher,
            credits: Double(first.CreditPoint) ?? 0,
            classroom: allClassrooms.joined(separator: ", "),
            enrolledCount: first.ChooseStudent ?? 0,
            maxCount: Int(first.Restrict2 ?? "0") ?? 0,
            schedule: mergedSchedule,
            moodleIdNumber: fallbackMoodleIdNumber ?? "\(first.Semester)\(first.CourseNo)",
            semester: semester,
            classroomMap: classroomMap,
            dimension: results.compactMap(\.Dimension).first { !$0.isEmpty } ?? "",
            allYear: results.compactMap(\.AllYear).first { !$0.isEmpty } ?? "",
            requireOption: results.compactMap(\.RequireOption).first { !$0.isEmpty } ?? ""
        )
    }

}

private extension CourseData {
    func course(in semester: String) -> SDCourse {
        SDCourse(
            courseNo: courseNo,
            courseName: courseName,
            instructor: instructor,
            credits: credits,
            classroom: classroom,
            enrolledCount: enrolledCount,
            maxCount: maxCount,
            schedule: schedule,
            moodleIdNumber: moodleIdNumber,
            semester: semester,
            classroomMap: classroomMap,
            dimension: dimension,
            allYear: allYear,
            requireOption: requireOption
        )
    }

    init(_ course: SDCourse) {
        self.init(
            courseNo: course.courseNo,
            courseName: course.courseName,
            instructor: course.instructor,
            credits: course.credits,
            classroom: course.classroom,
            enrolledCount: course.enrolledCount,
            maxCount: course.maxCount,
            schedule: course.schedule,
            moodleIdNumber: course.moodleIdNumber,
            classroomMap: course.classroomMap,
            dimension: course.dimension,
            allYear: course.allYear,
            requireOption: course.requireOption
        )
    }
}

/// When each term's roster request last went to the school. A request stays until a roster
/// arrives, so while course selection does not answer, a term is asked again after an hour, not
/// on every full sync.
nonisolated struct RosterRequestLog: Sendable {
    static let retryInterval: TimeInterval = 3600
    private var asked: [String: (signIn: AccountSession.Ticket, at: Date)] = [:]

    /// The terms of the snapshot's `roster_requests` to ask now, recorded as asked. A snapshot
    /// without the key, from a backend that predates it, requests nothing.
    mutating func termsToAsk(in snapshot: [String: Any], signIn: AccountSession.Ticket, now: Date) -> [String] {
        let due = Set(snapshot["roster_requests"] as? [String] ?? []).filter { term in
            guard let last = asked[term], last.signIn == signIn else { return true }
            return now.timeIntervalSince(last.at) >= Self.retryInterval || now < last.at
        }
        for term in due { asked[term] = (signIn, now) }
        return due.sorted()
    }
}
