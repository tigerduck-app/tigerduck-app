import Defaults
import Foundation

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
        Defaults.reset(.semesterResetAt)
    }

    /// The NTUST API returns `CourseName` and `CourseTeacher` in the request's language, so the
    /// file name holds the resolved course-API language, and switching the app language does not
    /// overwrite the other language's courses.
    func saveCourses(_ courses: [SDCourse], semester: String, language: String? = nil) {
        let file = coursesFilename(semester, language ?? currentCourseApiLanguage())
        cache.save(courses.map { CachedCourse(from: $0) }, to: file)
    }

    func loadCourses(semester: String, language: String? = nil) -> [SDCourse] {
        loadCoursesIfCached(semester: semester, language: language) ?? []
    }

    func loadCoursesIfCached(semester: String, language: String? = nil) -> [SDCourse]? {
        guard let dtos: [CachedCourse] = cache.load(coursesFilename(semester, language ?? currentCourseApiLanguage())) else {
            return nil
        }
        let customNames = loadCourseCustomNames()
        return dtos.map { applyCustomNameOverlay($0.toSDCourse(), customNames: customNames, clearPollutedCanonical: true) }
    }

    func clearCourses(semester: String) {
        folders.removeCacheFiles { $0.hasPrefix("courses_\(semester)_") }
    }

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

    func loadSemesterResetAt() -> [String: Date] {
        Defaults[.semesterResetAt]
    }

    func recordSemesterReset(_ semester: String, at date: Date = Date(), for signIn: SignIn) {
        Defaults[.semesterResetAt, for: signIn][semester] = date
    }

    func clearSemesterResets(outlivedBy fetchedAt: Date, keeping owned: Set<String> = [], for signIn: SignIn) {
        let all = loadSemesterResetAt()
        let kept = all.filter { owned.contains($0.key) || fetchedAt.timeIntervalSince($0.value) <= Self.semesterResetGrace }
        if kept.count != all.count {
            Defaults[.semesterResetAt, for: signIn] = kept
        }
    }

    private static let semesterResetGrace: TimeInterval = 60

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

    func saveSelectionDroppedNos(_ dropped: [String: [String]]) {
        persistent.save(dropped, to: "selection_dropped.json")
    }

    func loadSelectionDroppedNos() -> [String: [String]] {
        persistent.load("selection_dropped.json") ?? [:]
    }

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

    func recordRoster(_ source: TermRoster.RosterSource, semester: String) {
        var stored = loadSelectionDroppedNos()
        let previous = Set(stored[semester] ?? [])
        let updated = TermRoster.selectionDrops(
            previous: previous, localPortalNos: loadCourses(semester: semester).map(\.courseNo), roster: source
        )
        guard updated != previous else { return }
        if updated.isEmpty {
            stored.removeValue(forKey: semester)
        } else {
            stored[semester] = Array(updated).sorted()
        }
        saveSelectionDroppedNos(stored)
    }

    func saveDeletedCourseNos(_ courseNos: [String]) {
        persistent.save(courseNos, to: "deleted_courses.json")
    }

    /// See docs/decisions/0005-course-tombstones.md.
    func deleteCourse(_ courseNo: String, semester: String) {
        if !isLocalOnlyHandAdded(courseNo, semester: semester) { hide(courseNo, semester: semester) }
        removeAddedByHand(courseNo, semester: semester)
    }

    private func isLocalOnlyHandAdded(_ courseNo: String, semester: String) -> Bool {
        loadUserAddedCourses(semester: semester).contains { $0.courseNo == courseNo && $0.moodleIdNumber == nil }
            && !loadCourses(semester: semester).contains { $0.courseNo == courseNo }
    }

    private func hide(_ courseNo: String, semester: String) {
        let key = CourseTombstone.key(semester: semester, courseNo: courseNo)
        saveDeletedCourseNos(Array(Set(loadDeletedCourseNos()).union([key])))
    }

    private func removeAddedByHand(_ courseNo: String, semester: String) {
        let userAdded = loadUserAddedCourses()
        let kept = userAdded.filter { !($0.courseNo == courseNo && Self.userAddedCourse($0, belongsTo: semester)) }
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
