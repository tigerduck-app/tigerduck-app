import Foundation

/// Persists network-fetched data to disk so it survives app restarts.
/// Uses JSON files in the app's caches directory.
final class DataCache {
    static let shared = DataCache()

    private let cacheDir: URL
    private let persistentDir: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TigerDuckCache", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            AppLogger.captureError(error, context: ["phase": "dataCache.createCacheDir"])
        }
        cacheDir = dir

        let persistent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TigerDuckData", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: persistent, withIntermediateDirectories: true)
        } catch {
            AppLogger.captureError(error, context: ["phase": "dataCache.createPersistentDir"])
        }
        persistentDir = persistent

        absorbLegacyCourseCache()
    }

    // MARK: - Courses (semester-scoped)

    /// Save courses for a specific semester. Filename: courses_<semester>.json
    func saveCourses(_ courses: [SDCourse], semester: String) {
        let dtos = courses.map { CachedCourse(from: $0) }
        save(dtos, to: coursesFilename(semester))
    }

    /// Load courses for a specific semester. Returns [] if not yet cached.
    func loadCourses(semester: String) -> [SDCourse] {
        let dtos: [CachedCourse] = load(from: coursesFilename(semester)) ?? []
        return dtos.map { $0.toSDCourse() }
    }

    private func coursesFilename(_ semester: String) -> String {
        "courses_\(semester).json"
    }

    // MARK: - User-Added Courses

    func saveUserAddedCourses(_ courses: [SDCourse]) {
        let dtos = courses.map { CachedCourse(from: $0) }
        save(dtos, to: "user_added_courses.json", in: persistentDir)
    }

    func loadUserAddedCourses() -> [SDCourse] {
        let dtos: [CachedCourse] = load(from: "user_added_courses.json", in: persistentDir) ?? []
        return dtos.map { $0.toSDCourse() }
    }

    // MARK: - Assignments

    func saveAssignments(_ assignments: [SDAssignment]) {
        let dtos = assignments.map { CachedAssignment(from: $0) }
        save(dtos, to: "assignments.json")
    }

    func loadAssignments() -> [SDAssignment] {
        let dtos: [CachedAssignment] = load(from: "assignments.json") ?? []
        return dtos.map { $0.toSDAssignment() }
    }

    // MARK: - Calendar Events

    func saveCalendarEvents(_ events: [SDCalendarEvent]) {
        let dtos = events.map { CachedCalendarEvent(from: $0) }
        save(dtos, to: "calendar_events.json")
    }

    func loadCalendarEvents() -> [SDCalendarEvent] {
        let dtos: [CachedCalendarEvent] = load(from: "calendar_events.json") ?? []
        return dtos.map { $0.toSDCalendarEvent() }
    }

    // MARK: - Deleted Courses

    func saveDeletedCourseNos(_ courseNos: [String]) {
        save(courseNos, to: "deleted_courses.json", in: persistentDir)
    }

    func loadDeletedCourseNos() -> [String] {
        load(from: "deleted_courses.json", in: persistentDir) ?? []
    }

    // MARK: - Course Custom Names

    func saveCourseCustomNames(_ names: [String: String]) {
        save(names, to: "course_custom_names.json", in: persistentDir)
    }

    func loadCourseCustomNames() -> [String: String] {
        load(from: "course_custom_names.json", in: persistentDir) ?? [:]
    }

    // MARK: - Course Custom Colors

    /// Per-course palette-index overrides keyed by courseNo. Values index into
    /// `TigerDuckTheme.courseColors`; consumers must tolerate out-of-range
    /// indices (e.g. after the palette shrinks between releases).
    func saveCourseCustomColors(_ colors: [String: Int]) {
        save(colors, to: "course_custom_colors.json", in: persistentDir)
    }

    func loadCourseCustomColors() -> [String: Int] {
        load(from: "course_custom_colors.json", in: persistentDir) ?? [:]
    }

    // MARK: - User-scoped cleanup

    /// Remove every file that is scoped to the currently signed-in NTUST user.
    /// Called on logout so the next user never sees the previous user's data
    /// on the home screen, in the Live Activity, or in pending reminders.
    func clearUserScopedData() {
        let filenames: [(String, URL)] = [
            ("assignments.json", cacheDir),
            ("calendar_events.json", cacheDir),
            ("user_added_courses.json", persistentDir),
            ("deleted_courses.json", persistentDir),
            ("course_custom_names.json", persistentDir),
            ("course_custom_colors.json", persistentDir),
        ]
        for (name, dir) in filenames {
            let url = dir.appendingPathComponent(name)
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                let nsError = error as NSError
                // File not existing is expected — only report real failures.
                if !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError) {
                    AppLogger.captureError(error, context: [
                        "phase": "dataCache.clearUserScopedData",
                        "filename": name,
                    ])
                }
            }
        }

        let cacheContents = (try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in cacheContents where url.lastPathComponent.hasPrefix("courses_") && url.pathExtension == "json" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Private helpers

    private func save<T: Encodable>(_ value: T, to filename: String, in directory: URL? = nil) {
        let url = (directory ?? cacheDir).appendingPathComponent(filename)
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLogger.captureError(error, context: [
                "phase": "dataCache.save",
                "filename": filename,
            ])
        }
    }

    private func load<T: Decodable>(from filename: String, in directory: URL? = nil) -> T? {
        let url = (directory ?? cacheDir).appendingPathComponent(filename)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let nsError = error as NSError
            // First-run and post-logout reads on missing files are expected;
            // only report decode failures and unexpected IO errors.
            if !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError) {
                AppLogger.captureError(error, context: [
                    "phase": "dataCache.load.read",
                    "filename": filename,
                ])
            }
            return nil
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            AppLogger.captureError(error, context: [
                "phase": "dataCache.load.decode",
                "filename": filename,
            ])
            return nil
        }
    }

    // Legacy migration: absorb courses.json (pre-semester-scoped format) into courses_<current>.json
    private func absorbLegacyCourseCache() {
        let legacyURL = cacheDir.appendingPathComponent("courses.json")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }

        if let data = try? Data(contentsOf: legacyURL),
           let _ = try? decoder.decode([CachedCourse].self, from: data) {
            let current = CourseSelectionService.currentSemesterCode()
            let targetURL = cacheDir.appendingPathComponent("courses_\(current).json")
            // Only absorb if the semester file doesn't already exist (avoid overwriting fresh data)
            if !FileManager.default.fileExists(atPath: targetURL.path) {
                try? data.write(to: targetURL, options: .atomic)
            }
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }
}

// MARK: - Codable DTOs

private struct CachedCourse: Codable {
    let courseNo: String
    let courseName: String
    let instructor: String
    let credits: Int
    let classroom: String
    let enrolledCount: Int
    let maxCount: Int
    let scheduleJSON: String
    let moodleIdNumber: String?
    let semester: String?
    let classroomMapJSON: String?
    /// Persisted skip state for the course. Optional so older cache files
    /// written before this field existed continue to decode cleanly; falls
    /// back to "[]" (no skipped dates) when absent.
    let skippedDatesJSON: String?

    init(from course: SDCourse) {
        courseNo = course.courseNo
        courseName = course.courseName
        instructor = course.instructor
        credits = course.credits
        classroom = course.classroom
        enrolledCount = course.enrolledCount
        maxCount = course.maxCount
        scheduleJSON = course.scheduleJSON
        moodleIdNumber = course.moodleIdNumber
        semester = course.semester.isEmpty ? nil : course.semester
        classroomMapJSON = course.classroomMapJSON
        skippedDatesJSON = course.skippedDatesJSON
    }

    func toSDCourse() -> SDCourse {
        // Decode schedule from JSON to pass into init
        let schedule: [Int: [String]]
        if let data = scheduleJSON.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: [String]].self, from: data) {
            schedule = Dictionary(uniqueKeysWithValues: dict.compactMap { key, value in
                guard let intKey = Int(key) else { return nil }
                return (intKey, value)
            })
        } else {
            schedule = [:]
        }

        let classroomMap: [String: String]
        if let json = classroomMapJSON,
           let data = json.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            classroomMap = dict
        } else {
            classroomMap = [:]
        }

        let course = SDCourse(
            courseNo: courseNo,
            courseName: courseName,
            instructor: instructor,
            credits: credits,
            classroom: classroom,
            enrolledCount: enrolledCount,
            maxCount: maxCount,
            schedule: schedule,
            moodleIdNumber: moodleIdNumber,
            semester: semester ?? CourseSelectionService.currentSemesterCode(),
            classroomMap: classroomMap
        )
        course.skippedDatesJSON = skippedDatesJSON ?? "[]"
        return course
    }
}

private struct CachedAssignment: Codable {
    let assignmentId: String
    let courseNo: String
    let courseName: String
    let title: String
    let dueDate: Date
    let isCompleted: Bool
    let moodleUrl: String?
    /// Optional so cache files written before the field existed continue
    /// to decode; `nil` just means we have not yet learned the cutoff.
    let cutoffDate: Date?
    /// Optional for the same back-compat reason as `cutoffDate`.
    let submittedAt: Date?

    init(from assignment: SDAssignment) {
        assignmentId = assignment.assignmentId
        courseNo = assignment.courseNo
        courseName = assignment.courseName
        title = assignment.title
        dueDate = assignment.dueDate
        isCompleted = assignment.isCompleted
        moodleUrl = assignment.moodleUrl
        cutoffDate = assignment.cutoffDate
        submittedAt = assignment.submittedAt
    }

    func toSDAssignment() -> SDAssignment {
        SDAssignment(
            assignmentId: assignmentId,
            courseNo: courseNo,
            courseName: courseName,
            title: title,
            dueDate: dueDate,
            isCompleted: isCompleted,
            moodleUrl: moodleUrl,
            cutoffDate: cutoffDate,
            submittedAt: submittedAt
        )
    }
}

private struct CachedCalendarEvent: Codable {
    let eventId: String
    let title: String
    let date: Date
    let sourceRaw: String

    init(from event: SDCalendarEvent) {
        eventId = event.eventId
        title = event.title
        date = event.date
        sourceRaw = event.sourceRaw
    }

    func toSDCalendarEvent() -> SDCalendarEvent {
        SDCalendarEvent(
            eventId: eventId,
            title: title,
            date: date,
            source: EventSource(rawValue: sourceRaw) ?? .school
        )
    }
}
