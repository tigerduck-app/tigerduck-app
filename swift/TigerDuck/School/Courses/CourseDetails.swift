import Defaults
import Foundation

enum CourseDetails {

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
                return cached ?? CourseDataBuilder.fallbackCourseData(courseNo: courseNo, moodle: moodle, grade: grade)
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
            return cached ?? CourseDataBuilder.fallbackCourseData(courseNo: courseNo, moodle: moodle, grade: grade)
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
        let course = CourseDataBuilder.buildSDCourse(
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
        semester: String, for signIn: SignIn, courses: CourseStore = .shared,
        lookup: @escaping @MainActor @Sendable (_ semester: String, _ courseNo: String, _ language: String, _ fresh: Bool) async throws -> [CourseSearchResult] = {
            try await CourseLookupService.lookupCourse(semester: $0, courseNo: $1, language: $2, fresh: $3)
        }
    ) async -> [SDCourse] {
        let targets = courses.loadUserAddedCourses(semester: semester)
        guard !targets.isEmpty else { return [] }
        let display = courses.currentDisplay()
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
        guard courses.applyLookedUp(refreshed, semester: semester, enrolled: false, display: display, for: signIn)
            || signIn.isCurrent else { return [] }
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
        semester: String, for signIn: SignIn, courses: CourseStore = .shared,
        lookup: @escaping @MainActor @Sendable (_ semester: String, _ courseNo: String, _ language: String, _ fresh: Bool) async throws -> [CourseSearchResult] = {
            try await CourseLookupService.lookupCourse(semester: $0, courseNo: $1, language: $2, fresh: $3)
        }
    ) async -> Bool {
        let seeds = (courses.loadCourses(semester: semester) + courses.loadUserAddedCourses(semester: semester))
            .filter { $0.classroom.isEmpty }
            .map { ($0.courseNo, $0.moodleIdNumber) }
        guard !seeds.isEmpty else { return false }
        let display = courses.currentDisplay()

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
        return courses.applyLookedUp(found, semester: semester, enrolled: true, display: display, for: signIn)
    }
}
