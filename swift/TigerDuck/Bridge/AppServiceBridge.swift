import Foundation
import Defaults

private struct CourseData: Sendable {
    let courseNo: String
    var courseName: String
    let instructor: String
    let credits: Int
    var classroom: String
    let enrolledCount: Int
    let maxCount: Int
    let schedule: [Int: [String]]
    let moodleIdNumber: String?
    var classroomMap: [String: String]
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
        let moodleEnrolledCourses = (try? await MoodleEnrolledCoursesService.fetchEnrolled()) ?? []

        await withTaskGroup(of: Void.self) { group in
            for semester in computeAvailableSemesters() {
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
        // Snapshot the login generation before issuing the network call.
        // Any logout that happens while we are awaiting will bump this
        // counter, and the post-fetch save below skips the write so the
        // previous user's data does not land in DataCache after
        // `clearUserScopedData()` has already run.
        let startGeneration = authService.loginGeneration
        let currentSemester = CourseSelectionService.currentSemesterCode()
        let isCurrentSemester = semester == currentSemester
        let courseApiLanguage = LanguageManager.resolvedCourseApiLanguage(
            appLanguage: Defaults[.appLanguage]
        )
        let courseAbbrEnabled = Defaults[.useEnglishCourseAbbreviation]
        let classroomAbbrEnabled = Defaults[.useEnglishClassroomAbbreviation]
        let classroomMandarinDisplay = Defaults[.classroomMandarinDisplay]

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
            // NTUST SSO is the "nice to have" source here — Moodle's long-lived
            // OIDC token is the primary. If SSO is unreachable (cookies cleared,
            // credentials rotated, portal flaky), swallow the failure so we
            // still fall through to the Moodle path; otherwise the whole
            // fetch would throw, the catch below would return an empty cache,
            // and Home / Class Table / Time Machine would stay blank.
            var courseSelectionNos: [String] = []
            if isCurrentSemester {
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

            let moodleAll = if let moodleEnrolledCourses {
                moodleEnrolledCourses
            } else {
                try await MoodleEnrolledCoursesService.fetchEnrolled()
            }
            // Persist idnumber → numeric-id map so `SDCourse.moodleDeepLink`
            // can build `?id=N` redirects (Moodle Mobile's in-app router
            // rejects `?idnumber=…`). Whole-map overwrite — the fetched list
            // is the authoritative snapshot, so any idnumber missing from
            // it has been dropped on Moodle's side and we must not keep a
            // stale numeric id pointing at a dead course. Guarded by the
            // same login-generation + cancellation checks as the course
            // cache write below: if the user logged out while this fetch
            // was in flight, `clearUserScopedData` may have already wiped
            // the map, and resuming this write would resurrect the
            // previous user's enrolled-course ids on disk.
            let moodleIdMap = Dictionary(
                moodleAll.compactMap { entry -> (String, Int)? in
                    guard !entry.idnumber.isEmpty else { return nil }
                    return (entry.idnumber, entry.id)
                },
                uniquingKeysWith: { _, latest in latest }
            )
            if !Task.isCancelled,
               authService.loginGeneration == startGeneration {
                DataCache.shared.saveMoodleCourseIdMap(moodleIdMap)
            }

            let moodleForSemester = moodleAll.filter { $0.semester == semester }
            let moodleByNo = Dictionary(
                moodleForSemester.compactMap { course -> (String, MoodleEnrolledCourse)? in
                    guard !course.courseNo.isEmpty else { return nil }
                    return (course.courseNo, course)
                },
                uniquingKeysWith: { first, _ in first }
            )

            // Third enrollment source: historical transcript. The score
            // report is the authoritative list for past semesters (選課
            // system is current-semester-only and Moodle only covers
            // Moodle-enabled classes), and for the current term it absorbs
            // pending/exempted rows that the other sources may miss.
            // Withdrew (二次退選) is excluded — those are cancelled
            // enrollments and shouldn't render in the class table.
            let scoreCoursesForSemester: [CourseGrade] = DataCache.shared
                .loadScoreReport(studentId: studentId)?
                .report.courses
                .filter { $0.term == semester && $0.status != .withdrew && !$0.code.isEmpty } ?? []
            let scoreByNo = Dictionary(
                scoreCoursesForSemester.map { ($0.code, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            var orderedCourseNos: [String] = []
            var seenCourseNos = Set<String>()

            for courseNo in courseSelectionNos where seenCourseNos.insert(courseNo).inserted {
                orderedCourseNos.append(courseNo)
            }

            for moodleCourse in moodleForSemester {
                let courseNo = moodleCourse.courseNo
                guard !courseNo.isEmpty, seenCourseNos.insert(courseNo).inserted else { continue }
                orderedCourseNos.append(courseNo)
            }

            for grade in scoreCoursesForSemester
                where seenCourseNos.insert(grade.code).inserted {
                orderedCourseNos.append(grade.code)
            }

            let courseDataList = await withTaskGroup(of: CourseData?.self) { group in
                for courseNo in orderedCourseNos {
                    // Hop into MainActor for the body. `buildSDCourse` returns
                    // a SwiftData-managed `SDCourse` whose accessors are
                    // MainActor-isolated, and `NameAbbrService.shared` is a
                    // MainActor singleton — running the closure on MainActor
                    // avoids per-statement `MainActor.run` while leaving the
                    // network `lookupCourse(…)` to suspend cooperatively.
                    group.addTask { @MainActor in
                        do {
                            let results = try await CourseLookupService.lookupCourse(
                                semester: semester, courseNo: courseNo, language: courseApiLanguage
                            )

                            guard !results.isEmpty else {
                                return fallbackCourseData(
                                    courseNo: courseNo,
                                    moodle: moodleByNo[courseNo],
                                    grade: scoreByNo[courseNo]
                                )
                            }

                            let course = buildSDCourse(
                                from: results,
                                semester: semester,
                                fallbackMoodleIdNumber: moodleByNo[courseNo]?.idnumber
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
                                classroomMap: course.classroomMap
                            )
                            // Cache the raw API name so abbreviation toggles can re-derive
                            // without a network round-trip.
                            NameAbbrService.shared.storeRawName(
                                courseNo: data.courseNo, name: data.courseName
                            )
                            NameAbbrService.shared.storeRawClassroom(
                                courseNo: data.courseNo,
                                classroom: data.classroom,
                                map: data.classroomMap
                            )
                            let isEnglish = courseApiLanguage == "en"
                            if isEnglish && courseAbbrEnabled {
                                data.courseName = NameAbbrService.shared.abbreviateName(data.courseName)
                            }
                            if classroomAbbrEnabled || classroomMandarinDisplay != "original" {
                                data.classroom = NameAbbrService.shared.abbreviateClassroom(
                                    data.classroom, display: classroomMandarinDisplay
                                )
                                data.classroomMap = data.classroomMap.mapValues { val in
                                    NameAbbrService.shared.abbreviateClassroom(
                                        val, display: classroomMandarinDisplay
                                    )
                                }
                            }
                            return data
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
                    classroomMap: course.classroomMap
                )
            }

            // Drop the cache write when either the calling Task was
            // cancelled (covers AppState.syncTask in the background sync
            // path) or the login generation moved on (covers Home /
            // ClassTable / Calendar refresh paths whose Task is not owned
            // by AppState and therefore is not reached by syncTask?.cancel()).
            if !courses.isEmpty,
               !Task.isCancelled,
               authService.loginGeneration == startGeneration {
                DataCache.shared.saveCourses(courses, semester: semester)

                if Defaults[.cloudSyncEnabled], let atm = authService.authTokenManager {
                    let entries = courses.map { c in
                        PushAPI.CourseUploadEntry(
                            semester: semester,
                            courseNo: c.courseNo,
                            courseName: c.courseName,
                            courseNameEn: nil,
                            moodleId: c.moodleIdNumber,
                            credits: c.credits > 0 ? Double(c.credits) : nil,
                            classroom: c.classroom.isEmpty ? nil : c.classroom,
                            instructors: c.instructor.isEmpty ? nil : [c.instructor],
                            scheduleJson: c.schedule.isEmpty ? nil : Dictionary(uniqueKeysWithValues: c.schedule.map { ("\($0.key)", $0.value) }),
                            classroomMap: c.classroomMap.isEmpty ? nil : c.classroomMap
                        )
                    }
                    let colorMap = TigerDuckTheme.courseColorMap
                    let overrides = courses.compactMap { c -> PushAPI.CourseOverrideUploadEntry? in
                        guard let hex = colorMap[c.courseNo] else { return nil }
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
                classroomMap: [:]
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
                classroomMap: [:]
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
            credits: Int(first.CreditPoint) ?? 0,
            classroom: allClassrooms.joined(separator: ", "),
            enrolledCount: first.ChooseStudent ?? 0,
            maxCount: Int(first.Restrict2 ?? "0") ?? 0,
            schedule: mergedSchedule,
            moodleIdNumber: fallbackMoodleIdNumber ?? "\(first.Semester)\(first.CourseNo)",
            semester: semester,
            classroomMap: classroomMap
        )
    }

    private static func computeAvailableSemesters() -> [String] {
        var semesters: [String] = []
        var code = CourseSelectionService.currentSemesterCode()

        for _ in 0..<4 {
            semesters.append(code)
            code = CourseSelectionService.previousSemesterCode(code)
        }

        return semesters
    }

    static func fetchAssignments(authService: AuthService) async -> [SDAssignment] {
        let startGeneration = authService.loginGeneration
        guard authService.storedStudentId != nil,
              authService.storedPassword != nil else {
            return DataCache.shared.loadAssignments()
        }

        do {
            #if DEBUG
            try await ServerFailureSimulator.shared.check(.moodle)
            #endif
            let currentSemester = CourseSelectionService.currentSemesterCode()
            let currentCourses = DataCache.shared.loadCourses(semester: currentSemester)

            let moodleEnrolled = try await MoodleEnrolledCoursesService.fetchEnrolled()
            // Same idnumber → numeric-id snapshot as the course-table path.
            // Done here too because the assignments pipeline can run before
            // the course pipeline on a cold launch, and the deep-link button
            // shouldn't have to wait two cycles to light up. Whole-map
            // overwrite for the same staleness reason — `moodleEnrolled` is
            // the authoritative current-enrolment list. Guarded by the same
            // login-generation + cancellation checks as the assignments
            // cache write below: a fetch in flight when the user logs out
            // must not resurrect that user's enrolled-course ids on disk.
            let moodleIdMapForAssignments = Dictionary(
                moodleEnrolled.compactMap { entry -> (String, Int)? in
                    guard !entry.idnumber.isEmpty else { return nil }
                    return (entry.idnumber, entry.id)
                },
                uniquingKeysWith: { _, latest in latest }
            )
            if !Task.isCancelled,
               authService.loginGeneration == startGeneration {
                DataCache.shared.saveMoodleCourseIdMap(moodleIdMapForAssignments)
            }

            // On first launch the NTUST course cache is empty because
            // backgroundSync runs assignments + courses in parallel.
            // Without this fallback we'd filter against an empty set,
            // short-circuit to cached-empty assignments, and 作業 would
            // stay blank until a second launch. Prefer filtering to the
            // current course roster when it exists (handles drops), else
            // use the semester prefix on Moodle's idnumber.
            var currentCourseNos = Set(currentCourses.map(\.courseNo))
            for mc in moodleEnrolled where mc.semester == currentSemester && !mc.courseNo.isEmpty {
                currentCourseNos.insert(mc.courseNo)
            }
            let relevantCourses: [MoodleEnrolledCourse]
            if currentCourseNos.isEmpty {
                relevantCourses = moodleEnrolled.filter { $0.semester == currentSemester }
            } else {
                relevantCourses = moodleEnrolled.filter { currentCourseNos.contains($0.courseNo) }
            }
            let relevantMoodleCourseIds = relevantCourses.map(\.id)
            guard !relevantMoodleCourseIds.isEmpty else {
                return DataCache.shared.loadAssignments()
            }

            let records = try await MoodleAssignmentService.fetchAssignments(
                courseIds: relevantMoodleCourseIds
            )
            let moodleCoursesById = Dictionary(
                uniqueKeysWithValues: relevantCourses.map { ($0.id, $0) }
            )

            let statuses: [Int: MoodleSubmissionStatus] = await withTaskGroup(
                of: (Int, MoodleSubmissionStatus)?.self,
                returning: [Int: MoodleSubmissionStatus].self
            ) { group in
                for record in records {
                    group.addTask {
                        guard let status = try? await MoodleAssignmentService.fetchSubmissionStatus(
                            assignId: record.assignId
                        ) else {
                            return nil
                        }
                        return (record.assignId, status)
                    }
                }

                var result: [Int: MoodleSubmissionStatus] = [:]
                for await pair in group {
                    if let (id, status) = pair {
                        result[id] = status
                    }
                }
                return result
            }

            let locallyCompletedIds = DataCache.shared.loadLocallyCompletedAssignmentIds()
            let archivedIds = DataCache.shared.loadArchivedAssignmentIds()

            let freshAssignments: [SDAssignment] = records.compactMap { record in
                guard let dueDate = record.dueDate else { return nil }
                guard !record.noSubmissions else { return nil }

                let moodleCourse = moodleCoursesById[record.courseId]
                let status = statuses[record.assignId]
                let assignmentId = String(record.assignId)
                return SDAssignment(
                    assignmentId: assignmentId,
                    courseNo: moodleCourse?.courseNo ?? "",
                    courseName: moodleCourse.map { courseName(from: $0.fullname) } ?? "",
                    title: record.name,
                    dueDate: dueDate,
                    isCompleted: status?.isSubmitted ?? false,
                    isArchived: archivedIds.contains(assignmentId),
                    isLocallyCompleted: locallyCompletedIds.contains(assignmentId),
                    moodleUrl: "https://moodle2.ntust.edu.tw/mod/assign/view.php?id=\(record.cmId)",
                    cutoffDate: record.cutoffDate,
                    submittedAt: status?.submittedAt
                )
            }

            let assignmentsToPersist: [SDAssignment]
            if statuses.count < records.count {
                assignmentsToPersist = preserveCompletionState(
                    freshAssignments: freshAssignments,
                    cachedAssignments: DataCache.shared.loadAssignments()
                )
            } else {
                assignmentsToPersist = freshAssignments
            }

            if !Task.isCancelled,
               authService.loginGeneration == startGeneration {
                DataCache.shared.saveAssignments(assignmentsToPersist)

                // Fire-and-forget: upload the assignment list to the backend
                // so it can populate its assignments table for cross-device
                // sync and notification scheduling.
                #if os(iOS)
                if Defaults[.cloudSyncEnabled], let atm = authService.authTokenManager {
                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime]
                    let entries = assignmentsToPersist.compactMap { a -> PushAPI.AssignmentUploadEntry? in
                        guard let id = Int(a.assignmentId) else { return nil }
                        return PushAPI.AssignmentUploadEntry(
                            moodleAssignmentId: id,
                            courseNo: a.courseNo,
                            courseName: a.courseName,
                            title: a.title,
                            dueAt: iso.string(from: a.dueDate),
                            moodleUrl: a.moodleUrl,
                            isSubmitted: a.isCompleted,
                            grade: nil
                        )
                    }
                    let client = PushAPIClient(
                        authHeaderProvider: { await atm.authorizationHeader() }
                    )
                    Task.detached {
                        try? await client.uploadAssignments(
                            PushAPI.AssignmentUploadRequest(assignments: entries)
                        )
                    }
                }
                #endif
            }
            await MainActor.run { ServerStatusTracker.shared.set(.ok, for: .moodle) }
            return assignmentsToPersist
        } catch {
            await MainActor.run {
                ServerStatusTracker.shared.set(.failed, for: .moodle)
                AppLogger.captureError(error, context: ["bridge": "fetchAssignments"])
            }
            return DataCache.shared.loadAssignments()
        }
    }

    static func preserveCompletionState(
        freshAssignments: [SDAssignment],
        cachedAssignments: [SDAssignment]
    ) -> [SDAssignment] {
        // When the per-assignment submission-status fetch partially fails,
        // we keep the previously known isCompleted so the UI does not
        // regress from "已繳交" back to "未繳交". Preserve submittedAt too:
        // without it we could not distinguish 已繳交 from 已遲交 after the
        // transient failure.
        let previousById = Dictionary(
            uniqueKeysWithValues: cachedAssignments.map { ($0.assignmentId, $0) }
        )

        for assignment in freshAssignments {
            guard let previous = previousById[assignment.assignmentId],
                  previous.isCompleted else { continue }
            assignment.isCompleted = true
            if assignment.submittedAt == nil {
                assignment.submittedAt = previous.submittedAt
            }
        }

        return freshAssignments
    }

    /// Course-no prefix matcher used to strip the leading code from a
    /// Moodle fullname like "EE3001 電子學". Hoisted to a static so it
    /// isn't recompiled per assignment / per call.
    private static let courseNoPrefixRegex: NSRegularExpression = {
        // Anchored: must match the whole token.
        try! NSRegularExpression(pattern: "^3?[A-Z]{2}[A-Z0-9]{6,7}$")
    }()

    private static func courseName(from fullname: String) -> String {
        let parts = fullname.components(separatedBy: " ")
        guard parts.count >= 2 else { return fullname }

        if let index = parts.firstIndex(where: { part in
            let range = NSRange(part.startIndex..<part.endIndex, in: part)
            return courseNoPrefixRegex.firstMatch(in: part, range: range) != nil
        }), index + 1 < parts.count {
            return parts[(index + 1)...].joined(separator: " ")
        }

        return fullname
    }

}
