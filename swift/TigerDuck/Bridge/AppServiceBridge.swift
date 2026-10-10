import Foundation
import Defaults

private struct CourseData: Sendable {
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
}

enum AppServiceBridge {

    /// Fetch and enrich enrolled courses.
    ///
    /// Pass `forceRefresh: true` to bust the `CourseService`
    /// enrolled-course-nos cache (ClassTable pull-to-refresh does this);
    /// default `false` lets the 24h cache absorb cheap refreshes.
    static func fetchCourses(
        authService: AuthService,
        semester: String = CourseSelectionService.currentSemesterCode(),
        forceRefresh: Bool = false
    ) async -> [SDCourse] {
        await fetchCourses(
            authService: authService,
            semester: semester,
            forceRefresh: forceRefresh,
            moodleEnrolledCourses: nil
        )
    }

    /// Called when the user changes the app language.
    /// Clears the NameAbbrService raw-name cache so the next fetch
    /// re-stores names in the new locale.
    static func handleLanguageChange() {
        NameAbbrService.shared.clearRawNameCache()
    }

    static func warmAllSemesterCaches(authService: AuthService) async {
        // Before anything else, so a newly published term (and the term the
        // course-selection system serves) is known to both the warm list below
        // and the enrolment attribution inside `fetchCourses`.
        await SemesterCatalog.refreshIfStale()
        let moodleEnrolledCourses = (try? await MoodleEnrolledCoursesService.fetchEnrolled()) ?? []

        await withTaskGroup(of: Void.self) { group in
            for semester in SemesterCatalog.availableSemesters() {
                guard DataCache.shared.loadCourses(semester: semester).isEmpty else { continue }
                group.addTask {
                    _ = await fetchCourses(
                        authService: authService,
                        semester: semester,
                        forceRefresh: false,
                        moodleEnrolledCourses: moodleEnrolledCourses
                    )
                }
            }
        }
    }

    private static func fetchCourses(
        authService: AuthService,
        semester: String,
        forceRefresh: Bool,
        moodleEnrolledCourses: [MoodleEnrolledCourse]?
    ) async -> [SDCourse] {
        // Snapshot before any network call: a logout while awaiting bumps the
        // generation and the saves below then skip, so the previous user's data
        // cannot land in DataCache after `clearUserScopedData()` has run.
        let startGeneration = authService.loginGeneration
        // Background sync fetches courses without going through
        // `warmAllSemesterCaches`, so resolve the catalogue here too — it is
        // TTL-throttled, so the concurrent warm fan-out costs one request.
        await SemesterCatalog.refreshIfStale()
        // The course-selection system serves one term and its list has no term
        // marker, so its numbers belong to the term the catalogue reports open.
        // `currentSemesterCode()` lags: its month heuristic would misfile them for weeks.
        let servesSelectionSemester = semester == SemesterCatalog.selectionSemesterCode()
        let display = CourseDisplayPreferences.current()
        let courseApiLanguage = display.language

        guard !Task.isCancelled else { return [] }

        guard let studentId = authService.storedStudentId,
              let password = authService.storedPassword else {
            return DataCache.shared.loadCourses(semester: semester)
        }

        do {
            #if DEBUG
            try await ServerFailureSimulator.shared.check(.courseSelection)
            #endif
            let session = NTUSTSessionManager.shared.session
            // nil when course selection serves another term or fails: Moodle is the
            // source then; the error is swallowed so the course screens do not go blank.
            // An answer owns its term and Moodle only enriches; see `enrolledCourseNos`.
            var courseSelectionNos: [String]?
            if servesSelectionSemester {
                do {
                    courseSelectionNos = try await CourseSelectionService.fetchEnrolledCourseNos(
                        session: session,
                        studentId: studentId,
                        password: password,
                        forceRefresh: forceRefresh,
                        persistGuard: { @Sendable [weak authService] in
                            authService?.loginGeneration == startGeneration
                        }
                    )
                    await MainActor.run { ServerStatusTracker.shared.set(.ok, for: .courseSelection) }
                } catch {
                    await MainActor.run {
                        ServerStatusTracker.shared.set(.failed, for: .courseSelection)
                        AppLogger.captureError(error, context: [
                            "service": "fetchEnrolledCourseNos",
                            "semester": semester,
                            "fallback": "moodleOnly",
                        ])
                    }
                }
            }

            // Before anything overwrites the cache: a portal course missing from this
            // answer was dropped in add/drop, and the backend keeps serving it until
            // it is deleted by hand. See `DataCache.recordSelectionRoster`.
            if let courseSelectionNos {
                DataCache.shared.recordSelectionRoster(
                    semester: semester, roster: courseSelectionNos)
            }

            let moodleAll = if let moodleEnrolledCourses {
                moodleEnrolledCourses
            } else {
                try await MoodleEnrolledCoursesService.fetchEnrolled()
            }
            // Numeric ids for `SDCourse.moodleDeepLink`: Moodle Mobile rejects `?idnumber=`.
            // Replace the whole map: an idnumber missing from this snapshot is a dropped
            // course. The guard stops a mid-fetch logout from restoring the old user's ids.
            let moodleIdMap = moodleCourseIdMap(moodleAll)
            if !Task.isCancelled,
               authService.loginGeneration == startGeneration {
                DataCache.shared.saveMoodleCourseIdMap(moodleIdMap)
            }

            let moodleForSemester = moodleAll.filter { $0.semester == semester }
            // Own number only, no co-listed aliases: an alias would re-point the course's
            // `moodleIdNumber`, so `applyCourseOverrides` would stop matching cloud rows.
            // Deep links resolve through `buildSDCourse`'s fallback key without it.
            let moodleByNo = Dictionary(
                moodleForSemester.compactMap { course -> (String, MoodleEnrolledCourse)? in
                    guard !course.courseNo.isEmpty else { return nil }
                    return (course.courseNo, course)
                },
                uniquingKeysWith: { first, _ in first }
            )

            // Third source, the transcript: authoritative for past terms, since course
            // selection serves one term and Moodle only its own classes, and it adds this
            // term's pending or exempted rows. Withdrawn rows are cancelled, so skip them.
            let scoreCoursesForSemester: [CourseGrade] = DataCache.shared
                .loadScoreReport(studentId: studentId)?
                .report.courses
                .filter { $0.term == semester && $0.status != .withdrew && !$0.code.isEmpty } ?? []
            let scoreByNo = Dictionary(
                scoreCoursesForSemester.map { ($0.code, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            let orderedCourseNos = enrolledCourseNos(
                selection: courseSelectionNos,
                moodle: moodleForSemester.map(\.courseNo),
                transcript: scoreCoursesForSemester.map(\.code)
            )

            let courseDataList = await withTaskGroup(of: CourseData?.self) { group in
                for courseNo in orderedCourseNos {
                    // MainActor: `SDCourse` accessors and `NameAbbrService.shared` are
                    // MainActor-isolated, so this avoids a `MainActor.run` per statement.
                    // The network `lookupCourse(…)` still suspends cooperatively.
                    group.addTask { @MainActor in
                        do {
                            let results = try await CourseLookupService.lookupCourse(
                                semester: semester, courseNo: courseNo, language: courseApiLanguage,
                                fresh: forceRefresh
                            )

                            guard !results.isEmpty else {
                                return fallbackCourseData(
                                    courseNo: courseNo,
                                    moodle: moodleByNo[courseNo],
                                    grade: scoreByNo[courseNo]
                                )
                            }

                            return enrichedCourseData(
                                from: results,
                                semester: semester,
                                fallbackMoodleIdNumber: moodleByNo[courseNo]?.idnumber,
                                display: display
                            )
                        } catch {
                            await MainActor.run {
                                AppLogger.captureError(error, context: [
                                    "service": "courseLookup",
                                    "semester": semester,
                                    "courseNo": courseNo,
                                ])
                            }
                            return fallbackCourseData(
                                courseNo: courseNo,
                                moodle: moodleByNo[courseNo],
                                grade: scoreByNo[courseNo]
                            )
                        }
                    }
                }

                var results: [CourseData] = []
                for await data in group {
                    if let data { results.append(data) }
                }
                return results
            }

            let courses = courseDataList.map { course in
                SDCourse(
                    courseNo: course.courseNo,
                    courseName: course.courseName,
                    instructor: course.instructor,
                    credits: course.credits,
                    classroom: course.classroom,
                    enrolledCount: course.enrolledCount,
                    maxCount: course.maxCount,
                    schedule: course.schedule,
                    moodleIdNumber: course.moodleIdNumber,
                    semester: semester,
                    classroomMap: course.classroomMap,
                    dimension: course.dimension,
                    allYear: course.allYear
                )
            }

            // Skip the write if the Task was cancelled (`AppState.syncTask`) or the
            // login generation moved on: Home, Class Table and Calendar refreshes run
            // in Tasks that `syncTask?.cancel()` does not reach.
            if !courses.isEmpty,
               !Task.isCancelled,
               authService.loginGeneration == startGeneration {
                DataCache.shared.saveCourses(courses, semester: semester)

                if CourseUploadPolicy.uploadsCourses, let atm = authService.authTokenManager {
                    let entries = courses.map { c in
                        PushAPI.CourseUploadEntry(
                            semester: semester,
                            courseNo: c.courseNo,
                            courseName: c.courseName,
                            courseNameEn: nil,
                            moodleId: c.moodleIdNumber,
                            credits: c.credits > 0 ? c.credits : nil,
                            classroom: c.classroom.isEmpty ? nil : c.classroom,
                            instructors: c.instructor.isEmpty ? nil : [c.instructor],
                            scheduleJson: c.schedule.isEmpty ? nil : Dictionary(uniqueKeysWithValues: c.schedule.map { ("\($0.key)", $0.value) }),
                            classroomMap: c.classroomMap.isEmpty ? nil : c.classroomMap
                        )
                    }
                    let colorMap = TigerDuckTheme.courseColorMap
                    let sendColors = CourseUploadPolicy.uploadsCourseColors
                    let overrides = courses.compactMap { c -> PushAPI.CourseOverrideUploadEntry? in
                        guard sendColors, let hex = colorMap[c.courseNo] else { return nil }
                        return PushAPI.CourseOverrideUploadEntry(
                            courseKey: "client:\(semester):\(c.courseNo)",
                            colorHex: String(format: "#%06X", hex)
                        )
                    }
                    let client = PushAPIClient(
                        authHeaderProvider: { await atm.authorizationHeader() }
                    )
                    Task.detached {
                        try? await client.uploadCourses(
                            PushAPI.CourseUploadRequest(courses: entries, courseOverrides: overrides)
                        )
                    }
                }
            }
            return courses
        } catch {
            await MainActor.run {
                ServerStatusTracker.shared.set(.failed, for: .courseSelection)
                AppLogger.captureError(error, context: ["bridge": "fetchCourses", "semester": semester])
            }
            return DataCache.shared.loadCourses(semester: semester)
        }
    }

    /// The course numbers a term renders, in source priority order, deduped.
    ///
    /// A non-empty course-selection answer owns its term: Moodle keeps a dropped
    /// class and the cached transcript can predate the drop, so either would bring
    /// it back. Pass `selection` as nil for other terms or when it was unreachable;
    /// Moodle leads then and the transcript adds non-Moodle classes. An empty list
    /// counts as nil: the D01 regex scrape returns no matches, not an error, when the
    /// page drifts, and that is cached for a day, so it must not blank the term.
    static func enrolledCourseNos(
        selection: [String]?,
        moodle: [String],
        transcript: [String]
    ) -> [String] {
        let candidates: [String]
        if let selection, !selection.isEmpty {
            candidates = selection
        } else {
            candidates = moodle + transcript
        }
        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// `idnumber` → Moodle's numeric course id, for every code a course answers
    /// to. A co-listed course's second department code is only in its `fullname`
    /// (see ``MoodleEnrolledCourse/courseNos``), so a student enrolled through it
    /// would otherwise get no id and lose the "open in Moodle" button.
    ///
    /// Aliases go in first and real `idnumber`s overwrite them, so a course's own
    /// code beats another course's alias. Among aliases the first course wins;
    /// among real `idnumber`s the last does.
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

    /// Which of a Moodle course's numbers an assignment is filed under. A
    /// co-listed course's `courseNo` is whichever department Moodle lists first,
    /// not always the one the student enrolled through, so the code the class
    /// table holds wins. Course colour, the Live Activity's course lookup and
    /// the backend upload all join on this.
    ///
    /// Falls back to the course's own number when the class table has neither:
    /// the best answer on a cold launch, before the course cache lands.
    static func assignmentCourseNo(
        for course: MoodleEnrolledCourse,
        localCourseNos: Set<String>
    ) -> String {
        course.courseNos.first(where: localCourseNos.contains) ?? course.courseNo
    }

    /// The courses the course-selection system stopped listing for one term,
    /// updated from one successful, non-empty answer.
    ///
    /// Only drops this device saw count: `localPortalNos` are its portal courses
    /// now, so their difference from `roster` is what add/drop just removed. A
    /// snapshot could not tell a drop from another device's manual course: both
    /// are unlisted, with identical rows. A course listed again is cleared, and an
    /// empty `roster` (not consulted, or drifted) changes nothing.
    static func selectionDrops(
        previous: Set<String>,
        localPortalNos: [String],
        roster: [String]
    ) -> Set<String> {
        guard !roster.isEmpty else { return previous }
        let enrolled = Set(roster)
        return previous.union(localPortalNos).subtracting(enrolled)
    }

    /// The per-user display toggles a course lookup has to honour, read once
    /// per fetch so a concurrent fan-out sees one consistent set.
    private struct CourseDisplayPreferences: Sendable {
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

    /// QueryCourse rows → the display-ready course data the class table
    /// stores: merged schedule and per-slot rooms, raw names cached for the
    /// abbreviation toggles, and the current abbreviation / Mandarin-display
    /// preferences applied.
    private static func enrichedCourseData(
        from results: [CourseSearchResult],
        semester: String,
        fallbackMoodleIdNumber: String?,
        display: CourseDisplayPreferences
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
            allYear: course.allYear
        )
        // Cache the raw API name so abbreviation toggles can re-derive
        // without a network round-trip.
        NameAbbrService.shared.storeRawName(courseNo: data.courseNo, name: data.courseName)
        NameAbbrService.shared.storeRawClassroom(
            courseNo: data.courseNo, classroom: data.classroom, map: data.classroomMap
        )
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

    /// Re-queries every manually-added (or cross-device merged) course of
    /// `semester` so its headcount, credits, instructor, rooms and periods
    /// are as fresh as the portal courses. Those rows otherwise keep the
    /// snapshot taken when they were added. Rows the lookup cannot find
    /// keep that snapshot. Persists and returns the semester's user-added
    /// list.
    static func refreshUserAddedCourses(semester: String) async -> [SDCourse] {
        let stored = DataCache.shared.loadUserAddedCourses()
        let targets = stored.filter { DataCache.userAddedCourse($0, belongsTo: semester) }
        guard !targets.isEmpty else { return [] }
        let display = CourseDisplayPreferences.current()
        // Snapshot the MainActor-bound model fields before fanning out.
        let seeds = targets.map { ($0.courseNo, $0.moodleIdNumber, $0.semester.isEmpty ? semester : $0.semester) }

        var refreshed: [String: CourseData] = [:]
        await withTaskGroup(of: (String, CourseData?).self) { group in
            for (courseNo, moodleId, rowSemester) in seeds {
                group.addTask { @MainActor in
                    guard let results = try? await CourseLookupService.lookupCourse(
                        semester: rowSemester, courseNo: courseNo, language: display.language,
                        fresh: true
                    ), !results.isEmpty else { return (courseNo, nil) }
                    return (courseNo, enrichedCourseData(
                        from: results, semester: rowSemester,
                        fallbackMoodleIdNumber: moodleId, display: display
                    ))
                }
            }
            for await (courseNo, data) in group {
                if let data { refreshed[courseNo] = data }
            }
        }
        guard !refreshed.isEmpty else { return targets }

        let updated = stored.map { course -> SDCourse in
            guard DataCache.userAddedCourse(course, belongsTo: semester),
                  let data = refreshed[course.courseNo] else { return course }
            return course.updated(with: data)
        }
        DataCache.shared.saveUserAddedCourses(updated)
        return updated.filter { DataCache.userAddedCourse($0, belongsTo: semester) }
    }

    /// Looks up every course of `semester` that still has no classroom —
    /// rooms are announced late, and a lookup that failed once used to
    /// leave the cell blank until the next pull-to-refresh. Persists the
    /// rows that now carry one and returns whether anything changed.
    static func refreshCoursesMissingClassroom(semester: String) async -> Bool {
        let enrolled = DataCache.shared.loadCourses(semester: semester)
        let userAdded = DataCache.shared.loadUserAddedCourses()
        let isUserAddedHere: (SDCourse) -> Bool = { DataCache.userAddedCourse($0, belongsTo: semester) }
        let seeds = (enrolled + userAdded.filter(isUserAddedHere))
            .filter { $0.classroom.isEmpty }
            .map { ($0.courseNo, $0.moodleIdNumber) }
        guard !seeds.isEmpty else { return false }
        let display = CourseDisplayPreferences.current()

        var found: [String: CourseData] = [:]
        await withTaskGroup(of: (String, CourseData?).self) { group in
            for (courseNo, moodleId) in seeds {
                group.addTask { @MainActor in
                    guard let results = try? await CourseLookupService.lookupCourse(
                        semester: semester, courseNo: courseNo, language: display.language
                    ), !results.isEmpty else { return (courseNo, nil) }
                    let data = enrichedCourseData(
                        from: results, semester: semester,
                        fallbackMoodleIdNumber: moodleId, display: display
                    )
                    return (courseNo, data.classroom.isEmpty ? nil : data)
                }
            }
            for await (courseNo, data) in group {
                if let data { found[courseNo] = data }
            }
        }
        guard !found.isEmpty else { return false }

        if enrolled.contains(where: { found[$0.courseNo] != nil }) {
            DataCache.shared.saveCourses(
                enrolled.map { course in found[course.courseNo].map(course.updated) ?? course },
                semester: semester
            )
        }
        if userAdded.contains(where: { isUserAddedHere($0) && found[$0.courseNo] != nil }) {
            DataCache.shared.saveUserAddedCourses(userAdded.map { course in
                guard isUserAddedHere(course), let data = found[course.courseNo] else { return course }
                return course.updated(with: data)
            })
        }
        return true
    }

    /// Build a minimal `CourseData` when the QueryCourse API returns empty
    /// (common for historical semesters — NTUST only keeps the latest term
    /// or two indexed). Prefers Moodle's course-fullname because it usually
    /// carries the section suffix students recognize; falls back to the
    /// transcript's course name + credits as a last resort so the class
    /// table still lists every term the student was graded in. Returns nil
    /// only when both auxiliary sources are missing.
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
                allYear: ""
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
                allYear: ""
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
            // First *non-empty* rather than first row: a course split across
            // rows only carries its dimension on some of them.
            dimension: results.compactMap(\.Dimension).first { !$0.isEmpty } ?? "",
            allYear: results.compactMap(\.AllYear).first { !$0.isEmpty } ?? ""
        )
    }

}


private extension SDCourse {
    /// The same row with a fresh lookup applied. Identity fields stay: a
    /// nil moodle id is what marks a row as manual, and `semester` is how
    /// legacy rows without one are told apart.
    func updated(with data: CourseData) -> SDCourse {
        SDCourse(
            courseNo: courseNo,
            courseName: data.courseName,
            instructor: data.instructor,
            credits: data.credits,
            classroom: data.classroom,
            enrolledCount: data.enrolledCount,
            maxCount: data.maxCount,
            schedule: data.schedule,
            moodleIdNumber: moodleIdNumber,
            semester: semester,
            classroomMap: data.classroomMap,
            dimension: data.dimension,
            allYear: data.allYear
        )
    }
}
