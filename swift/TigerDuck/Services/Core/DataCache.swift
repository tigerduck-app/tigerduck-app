import Defaults
import Foundation

/// Persists network-fetched data to disk as JSON files so it survives app restarts.
///
/// Stays on `@MainActor` (the module-default isolation under
/// `SWIFT_APPROACHABLE_CONCURRENCY = YES`) because the public surface
/// hands back SwiftData-managed types (`SDCourse`, `SDAssignment`,
/// `SDCalendarEvent`) whose accessors are themselves MainActor-isolated.
/// Callers running off MainActor (e.g. `Task.detached`) must hop via
/// `await MainActor.run { … }` before touching the cache.
final class DataCache {
    static let shared = DataCache()

    private let cacheDir: URL
    private let persistentDir: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private(set) var revision = 0

    private convenience init() {
        self.init(
            cacheDir: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TigerDuckCache", isDirectory: true),
            persistentDir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TigerDuckData", isDirectory: true)
        )
    }

    init(cacheDir: URL, persistentDir: URL) {
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        } catch {
            AppLogger.captureError(error, context: ["phase": "dataCache.createCacheDir"])
        }
        self.cacheDir = cacheDir

        do {
            try FileManager.default.createDirectory(at: persistentDir, withIntermediateDirectories: true)
        } catch {
            AppLogger.captureError(error, context: ["phase": "dataCache.createPersistentDir"])
        }
        self.persistentDir = persistentDir
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

    func loadCourses(semester: String) -> [SDCourse] {
        let dtos: [CachedCourse] = load(from: coursesFilename(semester, currentCourseApiLanguage())) ?? []
        let customNames = loadCourseCustomNames()
        return dtos.map { dto in
            applyCustomNameOverlay(
                dto.toSDCourse(),
                customNames: customNames,
                clearPollutedCanonical: true
            )
        }
    }

    func clearCourses(semester: String) {
        let prefix = "courses_\(semester)_"
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents
        where url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "json" {
            try? FileManager.default.removeItem(at: url)
        }
        revision &+= 1
    }

    private func coursesFilename(_ semester: String, _ language: String) -> String {
        "courses_\(semester)_\(language).json"
    }

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

    private func currentCourseApiLanguage() -> String {
        LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage])
    }

    func saveUserAddedCourses(_ courses: [SDCourse]) {
        let dtos = courses.map { CachedCourse(from: $0) }
        save(dtos, to: "user_added_courses.json", in: persistentDir)
    }

    static func userAddedCourse(_ course: SDCourse, belongsTo semester: String) -> Bool {
        course.semester == semester || course.semester.isEmpty
    }

    func loadUserAddedCourses(semester: String) -> [SDCourse] {
        loadUserAddedCourses().filter { Self.userAddedCourse($0, belongsTo: semester) }
    }

    func loadUserAddedCourses() -> [SDCourse] {
        let dtos: [CachedCourse] = load(from: "user_added_courses.json", in: persistentDir) ?? []
        let customNames = loadCourseCustomNames()
        return dtos.map { dto in
            applyCustomNameOverlay(
                dto.toSDCourse(),
                customNames: customNames,
                clearPollutedCanonical: false
            )
        }
    }

    private func applyCustomNameOverlay(
        _ course: SDCourse,
        customNames: [String: [String: String]],
        clearPollutedCanonical: Bool
    ) -> SDCourse {
        let locale = currentCourseApiLanguage()
        if let alias = customNames[course.courseNo]?[locale] {
            if clearPollutedCanonical, alias == course.courseName {
                course.courseName = ""
            }
            course.customName = alias
        }
        return course
    }

    func saveAssignments(_ assignments: [SDAssignment]) {
        let dtos = assignments.map { CachedAssignment(from: $0) }
        save(dtos, to: "assignments.json")
    }

    func loadAssignments(semester: String = CourseSelectionService.currentSemesterCode()) -> [SDAssignment] {
        let dtos: [CachedAssignment] = load(from: "assignments.json") ?? []
        let marks = assignmentMarks(semester: semester)
        return dtos.map { marks.apply(to: $0.toSDAssignment()) }
    }

    func assignmentMarks(semester: String) -> AssignmentMarks {
        AssignmentMarks(
            archivedIds: loadArchivedAssignmentIds(),
            locallyCompletedIds: loadLocallyCompletedAssignmentIds(),
            ignoredCourses: loadIgnoredAssignmentCourses(),
            semester: semester
        )
    }

    func loadIgnoredAssignmentCourses() -> Set<String> {
        let keys: [String] = load(from: "ignored_courses.json", in: persistentDir) ?? []
        return Set(keys)
    }

    func replaceIgnoredAssignmentCourses(_ keys: Set<String>) {
        save(keys.sorted(), to: "ignored_courses.json", in: persistentDir)
    }

    func setAssignmentsIgnored(_ ignored: Bool, semester: String, courseNo: String) {
        var keys = loadIgnoredAssignmentCourses()
        let key = CourseTombstone.key(semester: semester, courseNo: courseNo)
        if ignored { keys.insert(key) } else { keys.remove(key) }
        replaceIgnoredAssignmentCourses(keys)
    }

    func clearIgnoredAssignmentCourses(semester: String) {
        let prefix = CourseTombstone.key(semester: semester, courseNo: "")
        replaceIgnoredAssignmentCourses(loadIgnoredAssignmentCourses().filter { !$0.hasPrefix(prefix) })
    }

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

    func replaceArchivedAssignmentIds(_ ids: Set<String>) {
        save(Array(ids), to: "archived_assignments.json", in: persistentDir)
    }

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

    func replaceLocallyCompletedAssignmentIds(_ ids: Set<String>) {
        save(Array(ids), to: "locally_completed_assignments.json", in: persistentDir)
    }

    func loadClosedUnsubmittedAssignments() -> [String: Date] {
        load(from: "closed_unsubmitted_assignments.json") ?? [:]
    }

    func replaceClosedUnsubmittedAssignments(_ closed: [String: Date]) {
        save(closed, to: "closed_unsubmitted_assignments.json")
    }

    // MARK: - Course catalog (semester + language)

    /// The same for every account, so a sign-out keeps it. `nonisolated`: a body runs to a few
    /// megabytes, which the Add Course sheet reads and writes off the main thread.
    nonisolated func saveCourseCatalog(_ catalog: StoredCourseCatalog, semester: String, language: String) {
        let url = courseCatalogURL(semester: semester, language: language)
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(catalog).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            AppLogger.captureError(error, context: ["phase": "dataCache.saveCourseCatalog"])
        }
    }

    nonisolated func loadCourseCatalog(semester: String, language: String) -> StoredCourseCatalog? {
        let url = courseCatalogURL(semester: semester, language: language)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try PropertyListDecoder().decode(StoredCourseCatalog.self, from: data)
        } catch {
            AppLogger.captureError(error, context: ["phase": "dataCache.loadCourseCatalog"])
            return nil
        }
    }

    private nonisolated func courseCatalogURL(semester: String, language: String) -> URL {
        let term = String(semester.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
        return cacheDir.appendingPathComponent("course_catalog_\(term)_\(language).plist")
    }

    func saveBulletinSummaries(_ summaries: [BulletinAPI.BulletinSummary]) {
        save(summaries, to: "bulletin_summaries.json")
    }

    func loadBulletinSummaries() -> [BulletinAPI.BulletinSummary] {
        load(from: "bulletin_summaries.json") ?? []
    }

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

    func saveCalendarEvents(_ events: [SDCalendarEvent]) {
        let dtos = events.map { CachedCalendarEvent(from: $0) }
        save(dtos, to: "calendar_events.json")
    }

    func loadCalendarEvents() -> [SDCalendarEvent] {
        let dtos: [CachedCalendarEvent] = load(from: "calendar_events.json") ?? []
        return dtos.map { $0.toSDCalendarEvent() }
    }

    func saveSelectionDroppedNos(_ dropped: [String: [String]]) {
        save(dropped, to: "selection_dropped.json", in: persistentDir)
    }

    func loadSelectionDroppedNos() -> [String: [String]] {
        load(from: "selection_dropped.json", in: persistentDir) ?? [:]
    }

    func recordSelectionRoster(semester: String, roster: [String]) {
        guard !roster.isEmpty else { return }
        var stored = loadSelectionDroppedNos()
        let previous = Set(stored[semester] ?? [])
        let updated = AppServiceBridge.selectionDrops(
            previous: previous,
            localPortalNos: loadCourses(semester: semester).map(\.courseNo),
            roster: roster
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
        save(courseNos, to: "deleted_courses.json", in: persistentDir)
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
        let stored: [String] = load(from: "deleted_courses.json", in: persistentDir) ?? []
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
        save(names, to: "course_custom_names.json", in: persistentDir)
    }

    func loadCourseCustomNames() -> [String: [String: String]] {
        let url = persistentDir.appendingPathComponent("course_custom_names.json")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if let perLocale = try? decoder.decode([String: [String: String]].self, from: data) {
            return perLocale
        }
        guard let legacy = try? decoder.decode([String: String].self, from: data),
              !legacy.isEmpty
        else {
            return [:]
        }
        let locale = currentCourseApiLanguage()
        let migrated = legacy.mapValues { [locale: $0] }
        saveCourseCustomNames(migrated)
        return migrated
    }

    func loadCourseCustomNamesFlat() -> [String: String] {
        let locale = currentCourseApiLanguage()
        let perLocale = loadCourseCustomNames()
        var flat: [String: String] = [:]
        for (courseNo, locales) in perLocale {
            if let name = locales[locale] {
                flat[courseNo] = name
            }
        }
        return flat
    }

    func saveCourseColorMap(_ map: [String: UInt32]) {
        save(map, to: "course_color_map.json", in: persistentDir)
        if map.isEmpty { savePickedCourseColors([]) }
    }

    func loadPickedCourseColors() -> Set<String> {
        let courseNos: [String] = load(from: "picked_course_colors.json", in: persistentDir) ?? []
        return Set(courseNos)
    }

    func savePickedCourseColors(_ courseNos: Set<String>) {
        save(courseNos.sorted(), to: "picked_course_colors.json", in: persistentDir)
    }

    func notePickedCourseColor(_ courseNo: String) {
        savePickedCourseColors(loadPickedCourseColors().union([courseNo]))
    }

    /// The per-course color map, or nil while its file exists but cannot be read, as behind the
    /// lock screen (`completeFileProtectionUnlessOpen`). A missing file is an empty map.
    func loadCourseColorMapIfReadable() -> [String: UInt32]? {
        let url = persistentDir.appendingPathComponent("course_color_map.json")
        if FileManager.default.fileExists(atPath: url.path), (try? Data(contentsOf: url)) == nil { return nil }
        return loadCourseColorMap()
    }

    func loadCourseColorMap() -> [String: UInt32] {
        if let map: [String: UInt32] = load(from: "course_color_map.json", in: persistentDir) {
            return map
        }
        let legacy: [String: Int] = load(from: "course_custom_colors.json", in: persistentDir) ?? [:]
        guard !legacy.isEmpty else { return [:] }
        let migrated = legacy.compactMapValues { idx -> UInt32? in
            guard Self.legacyPaletteHex.indices.contains(idx) else { return nil }
            return Self.legacyPaletteHex[idx]
        }
        if !migrated.isEmpty {
            saveCourseColorMap(migrated)
        }
        return migrated
    }

    private static let legacyPaletteHex: [UInt32] = [
        0xFF6B6B, 0x4ECDC4, 0x45B7D1, 0xF39C12, 0xDDA0DD,
        0x2ECC71, 0xE74C3C, 0x3498DB, 0xF7DC6F, 0x9B59B6,
        0x1ABC9C, 0xE67E22, 0x85C1E9, 0xD35400, 0x27AE60,
        0xC0392B, 0x8E44AD, 0x16A085, 0xF1C40F, 0x2980B9,
    ]

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

    func loadScoreReport(studentId: String) -> (report: ScoreReport, cachedAt: Date)? {
        let envelope: CachedScoreReport? = load(from: scoreReportFilename(studentId))
        guard let envelope else { return nil }
        return (envelope.report, Date(timeIntervalSince1970: envelope.cachedAt))
    }

    func invalidateScoreReport(studentId: String) {
        let url = cacheDir.appendingPathComponent(scoreReportFilename(studentId))
        try? FileManager.default.removeItem(at: url)
        revision &+= 1
    }

    private func scoreReportFilename(_ studentId: String) -> String {
        "score_report_\(studentId).json"
    }

    func clearUserScopedData() {
        let filenames: [(String, URL)] = [
            ("assignments.json", cacheDir),
            ("closed_unsubmitted_assignments.json", cacheDir),
            ("calendar_events.json", cacheDir),
            ("user_added_courses.json", persistentDir),
            ("deleted_courses.json", persistentDir),
            ("selection_dropped.json", persistentDir),
            ("course_custom_names.json", persistentDir),
            ("course_custom_colors.json", persistentDir),
            ("course_color_map.json", persistentDir),
            ("picked_course_colors.json", persistentDir),
            ("archived_assignments.json", persistentDir),
            ("locally_completed_assignments.json", persistentDir),
            ("ignored_courses.json", persistentDir),
            ("bulletin_summaries.json", cacheDir),
            ("moodle_course_id_map.json", persistentDir),
        ]
        for (name, dir) in filenames {
            let url = dir.appendingPathComponent(name)
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                let nsError = error as NSError
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
        let bulletinDetails = cacheDir.appendingPathComponent("bulletin_details", isDirectory: true)
        try? FileManager.default.removeItem(at: bulletinDetails)
        try? FileManager.default.removeItem(at: moodleDir)
        try? FileManager.default.removeItem(at: moodleFilesDir)
        revision &+= 1
    }

    func clearEverything() {
        for dir in [cacheDir, persistentDir] {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            )) ?? []
            for url in contents {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? FileManager.default.removeItem(at: moodleFilesDir)
        revision &+= 1
    }

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
        revision &+= 1
    }

    // MARK: - Moodle course id map (idnumber → numeric id)

    /// Persisted map from Moodle course idnumber to numeric id, saved by ``AppServiceBridge``
    /// whenever it fetches the user's enrolled courses. Moodle Mobile's deep-link router honors
    /// only `?id=N` redirects reliably (the web accepts `?idnumber=…`, the in-app handler does
    /// not), so deep links look the numeric id up here. Lives in ``persistentDir`` to survive
    /// cache sweeps of localized course data; cleared on logout by ``clearUserScopedData()``.
    /// Always overwrite the whole map with the fresh snapshot: merging would keep entries for
    /// courses the user left or whose id was reissued, and `SDCourse.moodleDeepLink` would
    /// point at a dead course.
    func saveMoodleCourseIdMap(_ map: [String: Int]) {
        save(map, to: "moodle_course_id_map.json", in: persistentDir)
    }

    func loadMoodleCourseIdMap() -> [String: Int] {
        load(from: "moodle_course_id_map.json", in: persistentDir) ?? [:]
    }

    func lookupMoodleCourseId(idnumber: String) -> Int? {
        guard !idnumber.isEmpty else { return nil }
        // Normalised on both sides: Moodle spells a summer term "114h" and
        // NTUST "114H", and a course row can hold either spelling.
        return loadMoodleCourseIdMap()[SDCourse.normalizedMoodleId(idnumber)]
    }

    func saveMoodleData<Value: Codable>(_ value: Value, fetchedAt: Date, name: String, account: String) {
        let url = moodleFileURL(name: name, account: account)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        save(MoodleCacheEntry(fetchedAt: fetchedAt, value: value), to: url.lastPathComponent, in: url.deletingLastPathComponent())
    }

    func loadMoodleData<Value: Codable>(_ type: Value.Type, name: String, account: String) -> (value: Value, fetchedAt: Date)? {
        let url = moodleFileURL(name: name, account: account)
        let entry: MoodleCacheEntry<Value>? = load(from: url.lastPathComponent, in: url.deletingLastPathComponent())
        return entry.map { ($0.value, $0.fetchedAt) }
    }

    private struct MoodleCacheEntry<Value: Codable>: Codable {
        let fetchedAt: Date
        let value: Value
    }

    private var moodleDir: URL { cacheDir.appendingPathComponent("moodle", isDirectory: true) }

    var moodleFilesDir: URL {
        cacheDir.deletingLastPathComponent().appendingPathComponent("Moodle", isDirectory: true)
    }

    private func moodleFileURL(name: String, account: String) -> URL {
        let folder = String(account.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
        return moodleDir
            .appendingPathComponent(folder.isEmpty ? "_" : folder, isDirectory: true)
            .appendingPathComponent(name + ".json")
    }

    private func save<T: Encodable>(_ value: T, to filename: String, in directory: URL? = nil) {
        let url = (directory ?? cacheDir).appendingPathComponent(filename)
        revision &+= 1
        do {
            let data = try encoder.encode(value)
            // `.completeFileProtectionUnlessOpen` keeps academic PII at rest unreadable from a
            // backup or a jailbroken device; "UnlessOpen" still lets background refreshes
            // rewrite the file while the device is locked.
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
}

struct AssignmentMarks {
    let archivedIds: Set<String>
    let locallyCompletedIds: Set<String>
    let ignoredCourses: Set<String>
    let semester: String

    func apply(to assignment: SDAssignment) -> SDAssignment {
        if archivedIds.contains(assignment.assignmentId) { assignment.isArchived = true }
        if locallyCompletedIds.contains(assignment.assignmentId) { assignment.isLocallyCompleted = true }
        let term = assignment.semester ?? semester
        if ignoredCourses.contains(CourseTombstone.key(semester: term, courseNo: assignment.courseNo)) {
            assignment.isArchived = true
            assignment.isLocallyCompleted = false
            assignment.isIgnoredByCourse = true
        }
        return assignment
    }
}

struct CachedCourse: Codable {
    let courseNo: String
    let courseName: String
    let instructor: String
    let credits: Double
    let classroom: String
    let enrolledCount: Int
    let maxCount: Int
    let scheduleJSON: String
    let moodleIdNumber: String?
    let semester: String?
    let classroomMapJSON: String?
    let skippedDatesJSON: String?
    let dimension: String?
    let allYear: String?
    let requireOption: String?

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
        dimension = course.dimension.isEmpty ? nil : course.dimension
        allYear = course.allYear.isEmpty ? nil : course.allYear
        requireOption = course.requireOption.isEmpty ? nil : course.requireOption
    }

    func toSDCourse() -> SDCourse {
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
            classroomMap: classroomMap,
            dimension: dimension ?? "",
            allYear: allYear ?? "",
            requireOption: requireOption ?? ""
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
    let cutoffDate: Date?
    let submittedAt: Date?
    let originalDueDate: Date?
    let extensionDueDate: Date?
    let semester: String?

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
        originalDueDate = assignment.originalDueDate
        extensionDueDate = assignment.extensionDueDate
        semester = assignment.semester
    }

    func toSDAssignment() -> SDAssignment {
        SDAssignment(
            assignmentId: assignmentId,
            courseNo: courseNo,
            courseName: courseName,
            title: title,
            dueDate: originalDueDate ?? dueDate,
            isCompleted: isCompleted,
            moodleUrl: moodleUrl,
            cutoffDate: cutoffDate,
            submittedAt: submittedAt,
            extensionDueDate: extensionDueDate,
            semester: semester
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
