import Foundation
import Defaults

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

    static var courseUploader: ((_ courses: [SDCourse], _ semester: String) -> Void)?
    static var assignmentUploader: ((PushAPI.AssignmentUploadRequest) -> Void)?

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

    static func handleLanguageChange() {
        NameAbbrService.shared.clearRawNameCache()
    }

    static func warmAllSemesterCaches(authService: AuthService) async {
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
        let startGeneration = authService.loginGeneration
        await SemesterCatalog.refreshIfStale()
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
                    await MainActor.run {
                        record(.ok, for: .courseSelection, round: startGeneration, authService: authService)
                    }
                } catch {
                    await MainActor.run {
                        record(.failed, for: .courseSelection, round: startGeneration, authService: authService)
                        AppLogger.captureError(error, context: [
                            "service": "fetchEnrolledCourseNos",
                            "semester": semester,
                            "fallback": "moodleOnly",
                        ])
                    }
                }
            }

            if let courseSelectionNos {
                DataCache.shared.recordSelectionRoster(
                    semester: semester, roster: courseSelectionNos)
            }

            let moodleAll = if let moodleEnrolledCourses {
                moodleEnrolledCourses
            } else {
                try await MoodleEnrolledCoursesService.fetchEnrolled()
            }
            let moodleIdMap = moodleCourseIdMap(moodleAll)
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
            let cachedByNo = Dictionary(
                DataCache.shared.loadCourses(semester: semester).map { ($0.courseNo, CourseData($0)) },
                uniquingKeysWith: { first, _ in first }
            )

            let courseDataList = await concurrentMap(orderedCourseNos) { @MainActor courseNo -> CourseData? in
                await refreshedCourseData(
                    courseNo: courseNo,
                    semester: semester,
                    cached: cachedByNo[courseNo],
                    moodle: moodleByNo[courseNo],
                    grade: scoreByNo[courseNo],
                    display: display
                ) {
                    try await CourseLookupService.lookupCourse(
                        semester: semester, courseNo: courseNo, language: courseApiLanguage,
                        fresh: forceRefresh
                    )
                }
            }.compactMap { $0 }

            let courses = courseDataList.map { $0.course(in: semester) }

            guard !Task.isCancelled, authService.loginGeneration == startGeneration else {
                return DataCache.shared.loadCourses(semester: semester)
            }
            if !courses.isEmpty {
                DataCache.shared.saveCourses(courses, semester: semester)
                uploadVisibleCourses(
                    courses, semester: semester, hidden: Set(DataCache.shared.loadDeletedCourseNos()), to: courseUploader
                )
            }
            return courses
        } catch {
            await MainActor.run {
                record(.failed, for: .courseSelection, round: startGeneration, authService: authService)
                AppLogger.captureError(error, context: ["bridge": "fetchCourses", "semester": semester])
            }
            return DataCache.shared.loadCourses(semester: semester)
        }
    }

    static func uploadVisibleCourses(
        _ courses: [SDCourse],
        semester: String,
        hidden: Set<String>,
        to upload: ((_ courses: [SDCourse], _ semester: String) -> Void)?
    ) {
        let visible = courses.filter { !CourseTombstone.isHidden($0.courseNo, semester: semester, in: hidden) }
        guard !visible.isEmpty else { return }
        upload?(visible, semester)
    }

    static func record(
        _ status: ServerStatus,
        for server: ServerKind,
        note: String? = nil,
        round startGeneration: Int,
        authService: AuthService,
        tracker: ServerStatusTracker = .shared
    ) {
        guard authService.loginGeneration == startGeneration else { return }
        tracker.set(status, for: server, note: note)
    }

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
        roster: [String]
    ) -> Set<String> {
        guard !roster.isEmpty else { return previous }
        let enrolled = Set(roster)
        return previous.union(localPortalNos).subtracting(enrolled)
    }

    struct CourseDisplayPreferences: Sendable {
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

    static func refreshUserAddedCourses(semester: String, authService: AuthService) async -> [SDCourse] {
        let startGeneration = authService.loginGeneration
        let stored = DataCache.shared.loadUserAddedCourses()
        let targets = stored.filter { DataCache.userAddedCourse($0, belongsTo: semester) }
        guard !targets.isEmpty else { return [] }
        let display = CourseDisplayPreferences.current()
        let seeds = targets.map { ($0.courseNo, $0.moodleIdNumber, $0.semester.isEmpty ? semester : $0.semester) }

        let lookups = await concurrentMap(seeds) { @MainActor seed -> (String, CourseData)? in
            let (courseNo, moodleId, rowSemester) = seed
            guard let results = try? await CourseLookupService.lookupCourse(
                semester: rowSemester, courseNo: courseNo, language: display.language,
                fresh: true
            ), !results.isEmpty else { return nil }
            return (courseNo, enrichedCourseData(
                from: results, semester: rowSemester,
                fallbackMoodleIdNumber: moodleId, display: display
            ))
        }
        let refreshed = Dictionary(lookups.compactMap { $0 }, uniquingKeysWith: { _, last in last })
        guard authService.loginGeneration == startGeneration else { return [] }
        guard !refreshed.isEmpty else { return targets }

        let updated = stored.map { course -> SDCourse in
            guard DataCache.userAddedCourse(course, belongsTo: semester),
                  let data = refreshed[course.courseNo] else { return course }
            return course.updated(with: data)
        }
        DataCache.shared.saveUserAddedCourses(updated)
        return updated.filter { DataCache.userAddedCourse($0, belongsTo: semester) }
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

    static func refreshCoursesMissingClassroom(semester: String, authService: AuthService) async -> Bool {
        let startGeneration = authService.loginGeneration
        let enrolled = DataCache.shared.loadCourses(semester: semester)
        let userAdded = DataCache.shared.loadUserAddedCourses()
        let isUserAddedHere: (SDCourse) -> Bool = { DataCache.userAddedCourse($0, belongsTo: semester) }
        let seeds = (enrolled + userAdded.filter(isUserAddedHere))
            .filter { $0.classroom.isEmpty }
            .map { ($0.courseNo, $0.moodleIdNumber) }
        guard !seeds.isEmpty else { return false }
        let display = CourseDisplayPreferences.current()

        let lookups = await concurrentMap(seeds) { @MainActor seed -> (String, CourseData)? in
            let (courseNo, moodleId) = seed
            guard let results = try? await CourseLookupService.lookupCourse(
                semester: semester, courseNo: courseNo, language: display.language
            ), !results.isEmpty else { return nil }
            let data = enrichedCourseData(
                from: results, semester: semester,
                fallbackMoodleIdNumber: moodleId, display: display
            )
            return data.classroom.isEmpty ? nil : (courseNo, data)
        }
        let found = Dictionary(lookups.compactMap { $0 }, uniquingKeysWith: { _, last in last })
        guard authService.loginGeneration == startGeneration, !found.isEmpty else { return false }

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


private extension SDCourse {
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
            allYear: data.allYear,
            requireOption: data.requireOption
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
