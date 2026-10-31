import Defaults
import Foundation

/// The school account's course files: each term's fetched courses in every language, the courses
/// added by hand, the hidden ones, the drops course selection and the server reported, and the
/// user's course names. `Stores/CourseStore.swift` reads and writes them; nothing else should.
///
/// On the main actor: it hands back `SDCourse`, whose accessors are main-actor isolated.
final class CourseFiles: AccountScoped {
    private let folders: CacheFolders
    private var cache: JSONFiles { folders.cacheFiles }
    private var persistent: JSONFiles { folders.persistentFiles }

    init(folders: CacheFolders = .app) {
        self.folders = folders
    }

    static func forgetAccount(in storage: AccountStorage) {
        let persistent = storage.folders.persistentFiles
        for name in [
            "user_added_courses.json", "deleted_courses.json", "selection_dropped.json", "server_dropped.json",
            "course_custom_names.json",
        ] {
            persistent.remove(name)
        }
        storage.folders.removeCacheFiles { $0.hasPrefix("courses_") }
    }

    // MARK: - Courses (semester + language-scoped)

    /// The NTUST API returns `CourseName` and `CourseTeacher` in the request's language, so the
    /// file name holds the resolved course-API language, and switching the app language does not
    /// overwrite the other language's courses.
    func saveCourses(_ courses: [SDCourse], semester: String) {
        cache.save(courses.map { CachedCourse(from: $0) }, to: coursesFilename(semester, currentCourseApiLanguage()))
    }

    func loadCourses(semester: String) -> [SDCourse] {
        let dtos: [CachedCourse] = cache.load(coursesFilename(semester, currentCourseApiLanguage())) ?? []
        let customNames = loadCourseCustomNames()
        return dtos.map { applyCustomNameOverlay($0.toSDCourse(), customNames: customNames, clearPollutedCanonical: true) }
    }

    func clearCourses(semester: String) {
        folders.removeCacheFiles { $0.hasPrefix("courses_\(semester)_") }
    }

    /// Removes the courses from the term's cache in every language, or switching the language
    /// would show one again.
    func removeCourses(_ courseNos: Set<String>, semester: String) {
        guard !courseNos.isEmpty else { return }
        let prefix = "courses_\(semester)_"
        let contents = (try? FileManager.default.contentsOfDirectory(at: folders.cache, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "json" {
            let dtos: [CachedCourse] = cache.load(url.lastPathComponent) ?? []
            let kept = dtos.filter { !courseNos.contains($0.courseNo) }
            if kept.count != dtos.count { cache.save(kept, to: url.lastPathComponent) }
        }
    }

    func clearCourseCaches() {
        folders.removeCacheFiles { $0.hasPrefix("courses_") }
    }

    private func coursesFilename(_ semester: String, _ language: String) -> String {
        "courses_\(semester)_\(language).json"
    }

    private func currentCourseApiLanguage() -> String {
        LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage])
    }

    // MARK: - Term resets

    func loadSemesterResetAt() -> [String: Date] {
        (UserDefaults.standard.dictionary(forKey: Self.semesterResetAtKey) as? [String: Date]) ?? [:]
    }

    func recordSemesterReset(_ semester: String, at date: Date = Date()) {
        var all = loadSemesterResetAt()
        all[semester] = date
        UserDefaults.standard.set(all, forKey: Self.semesterResetAtKey)
    }

    func clearSemesterResets(outlivedBy fetchedAt: Date) {
        let all = loadSemesterResetAt()
        let kept = all.filter { fetchedAt.timeIntervalSince($0.value) <= Self.semesterResetGrace }
        if kept.count != all.count {
            UserDefaults.standard.set(kept, forKey: Self.semesterResetAtKey)
        }
    }

    private static let semesterResetAtKey = "semesterResetAt"
    private static let semesterResetGrace: TimeInterval = 60

    // MARK: - Courses added by hand

    func saveUserAddedCourses(_ courses: [SDCourse]) {
        persistent.save(courses.map { CachedCourse(from: $0) }, to: "user_added_courses.json")
    }

    static func userAddedCourse(_ course: SDCourse, belongsTo semester: String) -> Bool {
        course.semester == semester || course.semester.isEmpty
    }

    func loadUserAddedCourses(semester: String) -> [SDCourse] {
        loadUserAddedCourses().filter { Self.userAddedCourse($0, belongsTo: semester) }
    }

    func loadUserAddedCourses() -> [SDCourse] {
        let dtos: [CachedCourse] = persistent.load("user_added_courses.json") ?? []
        let customNames = loadCourseCustomNames()
        return dtos.map { applyCustomNameOverlay($0.toSDCourse(), customNames: customNames, clearPollutedCanonical: false) }
    }

    private func applyCustomNameOverlay(
        _ course: SDCourse,
        customNames: [String: [String: String]],
        clearPollutedCanonical: Bool
    ) -> SDCourse {
        if let alias = customNames[course.courseNo]?[currentCourseApiLanguage()] {
            if clearPollutedCanonical, alias == course.courseName {
                course.courseName = ""
            }
            course.customName = alias
        }
        return course
    }

    // MARK: - Drops

    func saveSelectionDroppedNos(_ dropped: [String: [String]]) {
        persistent.save(dropped, to: "selection_dropped.json")
    }

    func loadSelectionDroppedNos() -> [String: [String]] {
        persistent.load("selection_dropped.json") ?? [:]
    }

    /// The term's courses the last full sync found dropped on the server. A fetch course selection
    /// did not answer leaves them out, as a running term's transcript may still list them.
    func saveServerDroppedNos(_ courseNos: Set<String>, semester: String) {
        var stored: [String: [String]] = persistent.load("server_dropped.json") ?? [:]
        guard Set(stored[semester] ?? []) != courseNos else { return }
        stored[semester] = courseNos.isEmpty ? nil : courseNos.sorted()
        persistent.save(stored, to: "server_dropped.json")
    }

    func loadServerDroppedNos(semester: String) -> Set<String> {
        let stored: [String: [String]] = persistent.load("server_dropped.json") ?? [:]
        return Set(stored[semester] ?? [])
    }

    /// The roster comes from course selection or, for a past term, the transcript. A course in
    /// `alsoListed`, which the term may hold on the server without this device having fetched it,
    /// is dropped too when the roster leaves it out. A final roster, an ended term's, counts even
    /// when empty; an empty course-selection answer may be a drifted page and records nothing.
    func recordSelectionRoster(semester: String, roster: [String], alsoListed: [String] = [], isFinal: Bool = false) {
        guard !roster.isEmpty || isFinal else { return }
        var stored = loadSelectionDroppedNos()
        let previous = Set(stored[semester] ?? [])
        let updated = AppServiceBridge.selectionDrops(
            previous: previous,
            localPortalNos: loadCourses(semester: semester).map(\.courseNo) + alsoListed,
            roster: roster,
            isFinal: isFinal
        )
        guard updated != previous else { return }
        if updated.isEmpty {
            stored.removeValue(forKey: semester)
        } else {
            stored[semester] = Array(updated).sorted()
        }
        saveSelectionDroppedNos(stored)
    }

    // MARK: - Hidden courses

    func saveDeletedCourseNos(_ courseNos: [String]) {
        persistent.save(courseNos, to: "deleted_courses.json")
    }

    /// Hides the course unless it was added by hand here: one with no Moodle ID that the school
    /// does not list for the term. That one is just removed, so the roster that lists it once the
    /// student enrolls shows and uploads it. A course merged from another device's row carries a
    /// Moodle ID and hides as before (docs/decisions/0005-course-tombstones.md).
    func deleteCourse(_ courseNo: String, semester: String) {
        let userAdded = loadUserAddedCourses()
        let isThisCourse = { (course: SDCourse) in
            course.courseNo == courseNo && Self.userAddedCourse(course, belongsTo: semester)
        }
        let kept = userAdded.filter { !isThisCourse($0) }
        let isHandAdded = userAdded.contains { isThisCourse($0) && $0.moodleIdNumber == nil }
            && !loadCourses(semester: semester).contains { $0.courseNo == courseNo }
        if !isHandAdded {
            let key = CourseTombstone.key(semester: semester, courseNo: courseNo)
            saveDeletedCourseNos(Array(Set(loadDeletedCourseNos()).union([key])))
        }
        if kept.count != userAdded.count { saveUserAddedCourses(kept) }
    }

    func loadDeletedCourseNos() -> [String] {
        let stored: [String] = persistent.load("deleted_courses.json") ?? []
        guard stored.contains(where: { !$0.contains(":") }) else { return stored }
        let rosters = Dictionary(
            SemesterCatalog.availableSemesters().map { ($0, Set(loadCourses(semester: $0).map(\.courseNo))) },
            uniquingKeysWith: { first, _ in first }
        )
        let migrated = CourseTombstone.migratingLegacyEntries(stored, rosters: rosters)
        if Set(migrated) != Set(stored) {
            saveDeletedCourseNos(migrated)
        }
        return migrated
    }

    // MARK: - Course names

    func saveCourseCustomNames(_ names: [String: [String: String]]) {
        persistent.save(names, to: "course_custom_names.json")
    }

    func loadCourseCustomNames() -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: persistent.url("course_custom_names.json")) else { return [:] }
        if let perLocale = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            return perLocale
        }
        guard let legacy = try? JSONDecoder().decode([String: String].self, from: data), !legacy.isEmpty else {
            return [:]
        }
        let locale = currentCourseApiLanguage()
        let migrated = legacy.mapValues { [locale: $0] }
        saveCourseCustomNames(migrated)
        return migrated
    }

    func loadCourseCustomNamesFlat() -> [String: String] {
        let locale = currentCourseApiLanguage()
        return loadCourseCustomNames().compactMapValues { $0[locale] }
    }
}
