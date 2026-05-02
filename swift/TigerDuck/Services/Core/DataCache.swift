import Defaults
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

    // MARK: - Courses (semester + language-scoped)

    /// Save courses for a specific semester. The NTUST API returns localized
    /// `CourseName` / `CourseTeacher` based on the request language, so the
    /// cache filename includes the resolved course-API language to keep
    /// per-language payloads from clobbering each other when the user toggles
    /// the app language.
    func saveCourses(_ courses: [SDCourse], semester: String) {
        let dtos = courses.map { CachedCourse(from: $0) }
        save(dtos, to: coursesFilename(semester, currentCourseApiLanguage()))
    }

    /// Load courses for a specific semester in the currently selected
    /// language. Returns [] if not yet cached for that language — the next
    /// network refresh will repopulate it.
    func loadCourses(semester: String) -> [SDCourse] {
        let dtos: [CachedCourse] = load(from: coursesFilename(semester, currentCourseApiLanguage())) ?? []
        return dtos.map { $0.toSDCourse() }
    }

    private func coursesFilename(_ semester: String, _ language: String) -> String {
        "courses_\(semester)_\(language).json"
    }

    private func currentCourseApiLanguage() -> String {
        LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage])
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
        let archivedIds = loadArchivedAssignmentIds()
        let locallyCompletedIds = loadLocallyCompletedAssignmentIds()
        return dtos.map { dto in
            let a = dto.toSDAssignment()
            if archivedIds.contains(a.assignmentId) { a.isArchived = true }
            if locallyCompletedIds.contains(a.assignmentId) { a.isLocallyCompleted = true }
            return a
        }
    }

    // MARK: - Archived Assignment IDs (local, persistent, survives Moodle refresh)

    func addArchivedAssignmentId(_ id: String) {
        var ids = loadArchivedAssignmentIds()
        ids.insert(id)
        save(Array(ids), to: "archived_assignments.json", in: persistentDir)
    }

    func removeArchivedAssignmentId(_ id: String) {
        var ids = loadArchivedAssignmentIds()
        ids.remove(id)
        save(Array(ids), to: "archived_assignments.json", in: persistentDir)
    }

    func loadArchivedAssignmentIds() -> Set<String> {
        let ids: [String] = load(from: "archived_assignments.json", in: persistentDir) ?? []
        return Set(ids)
    }

    // MARK: - Locally Completed Assignment IDs (local, persistent, survives Moodle refresh)

    func addLocallyCompletedAssignmentId(_ id: String) {
        var ids = loadLocallyCompletedAssignmentIds()
        ids.insert(id)
        save(Array(ids), to: "locally_completed_assignments.json", in: persistentDir)
    }

    func removeLocallyCompletedAssignmentId(_ id: String) {
        var ids = loadLocallyCompletedAssignmentIds()
        ids.remove(id)
        save(Array(ids), to: "locally_completed_assignments.json", in: persistentDir)
    }

    func loadLocallyCompletedAssignmentIds() -> Set<String> {
        let ids: [String] = load(from: "locally_completed_assignments.json", in: persistentDir) ?? []
        return Set(ids)
    }

    // MARK: - Bulletins

    /// Persist the full known list of bulletin summaries. Writes are
    /// atomic — callers should hand over the entire merged list, not a
    /// delta. The file survives app restarts so the list view can render
    /// instantly on launch while the VM refreshes against the server.
    func saveBulletinSummaries(_ summaries: [BulletinAPI.BulletinSummary]) {
        save(summaries, to: "bulletin_summaries.json")
    }

    func loadBulletinSummaries() -> [BulletinAPI.BulletinSummary] {
        load(from: "bulletin_summaries.json") ?? []
    }

    /// Persist a single bulletin detail. One file per id keeps writes
    /// small (~few KB) and avoids the append/rewrite cost a single
    /// aggregated file would have once we're past a few hundred items.
    func saveBulletinDetail(_ detail: BulletinAPI.BulletinDetail) {
        save(detail, to: bulletinDetailFilename(detail.id), in: bulletinDetailDir())
    }

    func loadBulletinDetail(id: Int) -> BulletinAPI.BulletinDetail? {
        load(from: bulletinDetailFilename(id), in: bulletinDetailDir())
    }

    private func bulletinDetailDir() -> URL {
        let dir = cacheDir.appendingPathComponent("bulletin_details", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bulletinDetailFilename(_ id: Int) -> String {
        "\(id).json"
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

    // MARK: - Score Report (per-student)

    /// Cache envelope that remembers when the payload was captured so callers
    /// can enforce TTL without threading a separate timestamp through
    /// `UserDefaults`.
    private struct CachedScoreReport: Codable {
        let report: ScoreReport
        let cachedAt: TimeInterval
    }

    func saveScoreReport(_ report: ScoreReport, studentId: String) {
        let envelope = CachedScoreReport(
            report: report,
            cachedAt: Date().timeIntervalSince1970
        )
        save(envelope, to: scoreReportFilename(studentId))
    }

    /// Returns the cached report together with the moment it was captured, so
    /// the caller can decide whether to honor a stale-while-revalidate window
    /// or force a refetch.
    func loadScoreReport(studentId: String) -> (report: ScoreReport, cachedAt: Date)? {
        let envelope: CachedScoreReport? = load(from: scoreReportFilename(studentId))
        guard let envelope else { return nil }
        return (envelope.report, Date(timeIntervalSince1970: envelope.cachedAt))
    }

    func invalidateScoreReport(studentId: String) {
        let url = cacheDir.appendingPathComponent(scoreReportFilename(studentId))
        try? FileManager.default.removeItem(at: url)
    }

    private func scoreReportFilename(_ studentId: String) -> String {
        "score_report_\(studentId).json"
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
            ("archived_assignments.json", persistentDir),
            ("locally_completed_assignments.json", persistentDir),
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
        for url in cacheContents where url.pathExtension == "json" {
            let name = url.lastPathComponent
            if name.hasPrefix("courses_") || name.hasPrefix("score_report_") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Remove every `courses_<semester>.json` file. Used by the abbreviation
    /// pipeline migration to drop pre-fix entries whose `classroomMapJSON`
    /// may already be abbreviated and would no longer round-trip through the
    /// raw classroom cache. The next fetch repopulates from the network.
    func clearCourseCaches() {
        let cacheContents = (try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in cacheContents where url.pathExtension == "json" {
            if url.lastPathComponent.hasPrefix("courses_") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Private helpers

    private func save<T: Encodable>(_ value: T, to filename: String, in directory: URL? = nil) {
        let url = (directory ?? cacheDir).appendingPathComponent(filename)
        do {
            let data = try encoder.encode(value)
            // .completeFileProtectionUnlessOpen keeps academic PII at rest
            // unreadable from a backup or jailbroken device; the
            // "UnlessOpen" variant lets background refreshes still rewrite
            // the file while the device is locked.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
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

    // Legacy migration:
    //   * `courses.json`              — pre-semester-scoped
    //   * `courses_<semester>.json`   — pre-language-scoped (NTUST API
    //                                    returns localized names, so the
    //                                    payload is implicitly tied to
    //                                    whatever language the last fetch
    //                                    used; we cannot recover that, so
    //                                    we just delete and let the next
    //                                    network refresh repopulate)
    private func absorbLegacyCourseCache() {
        let legacyURL = cacheDir.appendingPathComponent("courses.json")
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            try? FileManager.default.removeItem(at: legacyURL)
        }

        let cacheContents = (try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in cacheContents where url.pathExtension == "json" {
            let name = url.deletingPathExtension().lastPathComponent
            // Match the old `courses_<semester>` shape (exactly one
            // underscore-delimited segment after the prefix). The new
            // language-suffixed names have two segments and stay put.
            guard name.hasPrefix("courses_") else { continue }
            let suffix = String(name.dropFirst("courses_".count))
            if !suffix.contains("_") {
                try? FileManager.default.removeItem(at: url)
            }
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
