import Defaults
import SwiftUI

@Observable
final class ClassTableViewModel {
    var courses: [SDCourse] = [] {
        didSet { rebuildLookup() }
    }
    var assignments: [SDAssignment] = []
    var selectedCourse: SDCourse? = nil

    var selectedWeekday: Int? = nil
    var selectedPeriodId: String? = nil

    var currentSemester: String = Defaults[.classTableSelectedSemester] {
        didSet {
            guard currentSemester != oldValue else { return }
            Defaults[.classTableSelectedSemester] = currentSemester
            reloadFromCache()
        }
    }
    let availableSemesters: [String] = {
        let code = CourseSelectionService.currentSemesterCode()
        // Defensive parsing: a future `currentSemesterCode()` returning
        // an empty string or a non-numeric trailing digit would crash
        // ClassTableView's default-init via the previous `code.last!` /
        // `Int(sem)!`. Fall back to `[code]` so the UI still renders.
        let yearStr = String(code.dropLast())
        guard let year = Int(yearStr),
              let lastChar = code.last,
              let s0 = Int(String(lastChar)) else {
            return [code]
        }
        var semesters: [String] = []
        var y = year
        var s = s0
        for _ in 0..<4 {
            semesters.append("\(y)\(s)")
            s -= 1
            if s < 1 { s = 2; y -= 1 }
        }
        return semesters
    }()

    /// Format semester code for display: "1142" → "114-2"
    func displayLabel(for code: String) -> String {
        guard code.count >= 2, let last = code.last else { return code }
        return String(code.dropLast()) + "-" + String(last)
    }

    private var hasWarmedCaches = false

    func warmCachesIfNeeded(authService: AuthService) async {
        guard !hasWarmedCaches else { return }
        hasWarmedCaches = true
        await AppServiceBridge.warmAllSemesterCaches(authService: authService)
        await MainActor.run { [weak self] in
            self?.reloadCurrentSemesterCourses()
        }
    }

    /// Silent background refresh for the currently-selected semester.
    /// Fires after the user picks a new semester from the dropdown so the
    /// cached snapshot we just rendered gets reconciled with the latest
    /// server state without blocking UI.
    func refreshSelectedSemester(authService: AuthService) async {
        let target = currentSemester
        let fresh = await AppServiceBridge.fetchCourses(
            authService: authService,
            semester: target
        )
        await MainActor.run { [weak self] in
            guard let self, self.currentSemester == target else { return }
            let userAdded = DataCache.shared.loadUserAddedCourses()
            let merged = self.buildCourseList(fresh, userAdded)
            // Silent overwrite: only swap in-memory list when content actually
            // changed, so SwiftUI doesn't churn on identical data.
            if merged.map(\.courseNo).sorted() != self.courses.map(\.courseNo).sorted() {
                self.courses = merged
            }
            if target == CourseSelectionService.currentSemesterCode() {
                self.currentSemesterCourses = merged
                self.refreshCourseColors()
            }
        }
    }

    var showAddCourse = false
    var courseToRename: SDCourse? = nil
    var renameText: String = ""
    var showRenameAlert = false

    /// Non-nil while the color picker sheet is presented. SwiftUI's
    /// `sheet(item:)` binding drives both presentation and dismissal, so
    /// setting this to nil closes the sheet.
    var courseToRecolor: SDCourse? = nil

    private var deletedCourseNos: Set<String> = []
    private var courseCustomNames: [String: String] = [:]

    /// weekday → period ID → SDCourse (built once when courses change)
    private var courseLookup: [Int: [String: SDCourse]] = [:]

    private var hasLoaded = false
    private var isUpdatingFromNetwork = false
    private var dataObserver: Any?
    private var languageObserver: Any?

    /// Guards the fire-and-forget pull-to-refresh path against overlapping
    /// fetches. ``triggerRefresh(authService:)`` flips this to `true` while
    /// a fetch is running; additional pulls within that window coalesce
    /// into a no-op instead of stacking concurrent Tasks that would race
    /// on DataCache writes and `dataDidUpdate` notifications.
    private var isRefreshing = false
    private var currentSemesterCourses: [SDCourse] = []
    private let courseProvider = CanonicalCourseProvider()

    init() {
        deletedCourseNos = Set(DataCache.shared.loadDeletedCourseNos())
        courseCustomNames = DataCache.shared.loadCourseCustomNames()

        dataObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.dataDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self?.isUpdatingFromNetwork != true else { return }
            self?.reloadFromCache()
        }

        languageObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.languageDidChange,
            object: nil,
            queue: .main
        ) { _ in
            // Drop the in-memory raw-name cache so the next fetch re-stores
            // names in the new locale. The root-view rebuild triggered by
            // TigerDuckApp will drive the actual re-fetch.
            AppServiceBridge.handleLanguageChange()
        }
    }

    deinit {
        if let observer = dataObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = languageObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func mergeWithUserAdded(_ primary: [SDCourse], _ userAdded: [SDCourse]) -> [SDCourse] {
        var merged = primary
        for course in userAdded {
            if !merged.contains(where: { $0.courseNo == course.courseNo }) {
                merged.append(course)
            }
        }
        return merged
    }

    private func buildCourseList(_ primary: [SDCourse], _ userAdded: [SDCourse]) -> [SDCourse] {
        var merged = mergeWithUserAdded(primary, userAdded)
        applyCustomizations(&merged)
        return merged
    }

    private func reloadFromCache() {
        // Re-read the per-user customization sets from disk on every reload
        // so that a logout (which deletes the backing files and posts
        // dataDidUpdate) actually clears the in-memory state. Loading from
        // disk just once at init left the previous account's deletions and
        // renames applied to the next user's class table for the rest of
        // the app session.
        deletedCourseNos = Set(DataCache.shared.loadDeletedCourseNos())
        courseCustomNames = DataCache.shared.loadCourseCustomNames()
        TigerDuckTheme.reloadCustomColors()
        reloadCurrentSemesterCourses()
        courses = buildCourseList(
            DataCache.shared.loadCourses(semester: currentSemester),
            DataCache.shared.loadUserAddedCourses()
        )
        assignments = DataCache.shared.loadAssignments()
    }

    private func rebuildLookup() {
        var lookup: [Int: [String: SDCourse]] = [:]
        for course in courses {
            for (weekday, periods) in course.schedule {
                for period in periods {
                    lookup[weekday, default: [:]][period] = course
                }
            }
        }
        courseLookup = lookup
        cellRoleCache.removeAll(keepingCapacity: true)
        refreshCourseColors()
    }

    /// Call whenever `activePeriods` can change independently of a full
    /// `rebuildLookup` (e.g. a future per-user period-visibility toggle, or
    /// an in-place `course.setSchedule(_:)` that doesn't reassign `courses`).
    /// The cache key is `(weekday, periodIndex)` where `periodIndex` is an
    /// index into `activePeriods`, so any shift in `activePeriods.count`
    /// makes bounds-guarded `.empty` entries stale and would hide real
    /// courses until the next rebuild.
    func invalidateCellRoleCache() {
        cellRoleCache.removeAll(keepingCapacity: true)
    }

    /// Memoised `cellRole(weekday:periodIndex:)` results. Invalidated whenever
    /// `courseLookup` is rebuilt (course list change). The grid view calls
    /// `cellRole` once per (weekday, periodIdx) per render, and the lookup
    /// inside is O(span) — caching keeps re-renders cheap.
    private var cellRoleCache: [CellRoleKey: CellRole] = [:]

    private struct CellRoleKey: Hashable {
        let weekday: Int
        let periodIndex: Int
    }

    private func reloadCurrentSemesterCourses() {
        currentSemesterCourses = courseProvider.currentCourses()
    }

    private func refreshCourseColors() {
        let courseNos = Set(courses.map(\.courseNo)).union(currentSemesterCourses.map(\.courseNo))
        TigerDuckTheme.buildCourseColorMap(courseNos: Array(courseNos))
    }

    var totalCredits: Int {
        courses.reduce(0) { $0 + $1.credits }
    }

    var selectedCourseTimeRange: String? {
        guard let course = selectedCourse, let weekday = selectedWeekday else { return nil }
        return course.timeRange(for: weekday)
    }

    var todayCourses: [SDCourse] { currentSemesterCourses.coursesForToday() }

    var activeWeekdays: [Int] {
        var days = Set<Int>()
        for course in courses {
            for day in course.schedule.keys { days.insert(day) }
        }
        var result = Array(1...5)
        if days.contains(6) { result.append(6) }
        if days.contains(7) { result.append(7) }
        return result.sorted()
    }

    var activePeriods: [TimetablePeriod] {
        var periodIds = Set(AppConstants.Periods.defaultVisible)
        for course in courses {
            for periods in course.schedule.values {
                for p in periods { periodIds.insert(p) }
            }
        }
        let order = AppConstants.Periods.chronologicalOrder
        return order.filter { periodIds.contains($0) }.compactMap { TimetablePeriod.byId[$0] }
    }

    func course(for weekday: Int, period: String) -> SDCourse? {
        courseLookup[weekday]?[period]
    }

    func hasAssignment(for courseNo: String) -> Bool {
        assignments.hasUnfinished(for: courseNo)
    }

    func assignmentsFor(courseNo: String) -> [SDAssignment] {
        assignments.unfinished(for: courseNo)
    }

    enum CellRole {
        case empty
        case blockStart(SDCourse, spanCount: Int)
        case blockContinuation
    }

    func cellRole(weekday: Int, periodIndex: Int) -> CellRole {
        let key = CellRoleKey(weekday: weekday, periodIndex: periodIndex)
        if let cached = cellRoleCache[key] { return cached }

        let periods = activePeriods
        guard periodIndex >= 0, periodIndex < periods.count else {
            cellRoleCache[key] = .empty
            return .empty
        }

        let period = periods[periodIndex]
        guard let course = course(for: weekday, period: period.id) else {
            cellRoleCache[key] = .empty
            return .empty
        }

        if periodIndex > 0 {
            let prevPeriod = periods[periodIndex - 1]
            if let prevCourse = self.course(for: weekday, period: prevPeriod.id),
               prevCourse.courseNo == course.courseNo {
                cellRoleCache[key] = .blockContinuation
                return .blockContinuation
            }
        }

        var span = 1
        var nextIdx = periodIndex + 1
        while nextIdx < periods.count {
            let nextPeriod = periods[nextIdx]
            if let nextCourse = self.course(for: weekday, period: nextPeriod.id),
               nextCourse.courseNo == course.courseNo {
                span += 1
                nextIdx += 1
            } else {
                break
            }
        }

        let role = CellRole.blockStart(course, spanCount: span)
        cellRoleCache[key] = role
        return role
    }

    func selectCourse(_ course: SDCourse, weekday: Int, periodId: String) {
        selectedWeekday = weekday
        selectedPeriodId = periodId
        selectedCourse = course
    }

    func addCourse(_ course: SDCourse) {
        if deletedCourseNos.remove(course.courseNo) != nil {
            DataCache.shared.saveDeletedCourseNos(Array(deletedCourseNos))
        }
        guard !courses.contains(where: { $0.courseNo == course.courseNo }) else { return }

        // Cache the freshly-fetched API values BEFORE any local mutation so
        // abbreviation toggles can round-trip without a network refetch
        // (mirrors AppServiceBridge.fetchCourses).
        NameAbbrService.shared.storeRawName(
            courseNo: course.courseNo, name: course.courseName
        )
        NameAbbrService.shared.storeRawClassroom(
            courseNo: course.courseNo,
            classroom: course.classroom,
            map: course.classroomMap
        )

        // Apply current display toggles immediately so a newly-added course
        // with a Mandarin classroom shows in the user's chosen form (pinyin /
        // translated / original) without requiring them to flip the toggle.
        NameAbbrService.shared.relabelInPlace(
            [course],
            courseAbbrEnabled: Defaults[.useEnglishCourseAbbreviation],
            classroomAbbrEnabled: Defaults[.useEnglishClassroomAbbreviation],
            classroomMandarinDisplay: Defaults[.classroomMandarinDisplay]
        )

        // Apply the custom-name overlay if one persists for this course
        // (e.g. user removed and re-added). Stored separately from the
        // canonical courseName so abbreviation toggles and refreshes still
        // round-trip the API value through `NameAbbrService`.
        course.customName = courseCustomNames[course.courseNo]

        courses.append(course)
        persistUserAddedCourses()
        broadcastLocalChange()
    }

    private func persistUserAddedCourses() {
        let userAdded = courses.filter { $0.moodleIdNumber == nil }
        DataCache.shared.saveUserAddedCourses(userAdded)
    }

    private func applyCustomizations(_ courses: inout [SDCourse]) {
        courses.removeAll { deletedCourseNos.contains($0.courseNo) }
        for course in courses {
            course.customName = courseCustomNames[course.courseNo]
        }
    }

    func deleteCourse(_ course: SDCourse) {
        courses.removeAll { $0.courseNo == course.courseNo }
        deletedCourseNos.insert(course.courseNo)
        DataCache.shared.saveDeletedCourseNos(Array(deletedCourseNos))
        persistUserAddedCourses()
        broadcastLocalChange()
    }

    func startRename(_ course: SDCourse) {
        courseToRename = course
        renameText = course.displayName
        showRenameAlert = true
    }

    func confirmRename() {
        guard let course = courseToRename else { return }
        // Trim whitespace *and* newlines so a pasted "\nDefault\n" still
        // collapses to empty and routes through the revert path instead of
        // saving an invisible/line-breaking alias.
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty (or unchanged-from-default) means the user wants to revert to
        // the canonical name. Clearing the override is also what the explicit
        // "Revert to default" button does.
        if trimmed.isEmpty || trimmed == course.courseName {
            revertRename(course)
            return
        }
        courseCustomNames[course.courseNo] = trimmed
        DataCache.shared.saveCourseCustomNames(courseCustomNames)
        course.customName = trimmed
        rebuildLookup()
        persistUserAddedCourses()
        courseToRename = nil
        broadcastLocalChange()
    }

    func revertRename(_ course: SDCourse) {
        courseCustomNames.removeValue(forKey: course.courseNo)
        DataCache.shared.saveCourseCustomNames(courseCustomNames)
        course.customName = nil
        rebuildLookup()
        persistUserAddedCourses()
        courseToRename = nil
        broadcastLocalChange()
    }

    func startRecolor(_ course: SDCourse) {
        courseToRecolor = course
    }

    /// Apply a palette index override for this course. Writes through
    /// TigerDuckTheme (which handles persistence) and broadcasts so Home,
    /// Class Table, and the Live Activity all refresh.
    func setCustomColor(paletteIndex: Int, for course: SDCourse) {
        TigerDuckTheme.setCustomColor(index: paletteIndex, for: course.courseNo)
        courseToRecolor = nil
        broadcastLocalChange()
    }

    /// Remove the user override so the course returns to its deterministic
    /// default color.
    func clearCustomColor(for course: SDCourse) {
        TigerDuckTheme.clearCustomColor(for: course.courseNo)
        courseToRecolor = nil
        broadcastLocalChange()
    }

    /// Wakes Home, the Live Activity coordinator, and any other observer
    /// that subscribes to `dataDidUpdate`. Local Class Table edits used to
    /// only update Class Table itself, so renamed/added/deleted courses
    /// would stay stale on Home and on the lock screen until an unrelated
    /// network sync or scene reactivation happened to fire the same
    /// notification. The self-observer guards against the resulting
    /// reload pulling stale persisted state — addCourse / deleteCourse /
    /// confirmRename always write through to DataCache before posting.
    private func broadcastLocalChange() {
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
    }

    func load(authService: AuthService) {
        guard !hasLoaded else { return }
        hasLoaded = true

        let cachedAssignments = DataCache.shared.loadAssignments()
        let merged = buildCourseList(
            DataCache.shared.loadCourses(semester: currentSemester),
            DataCache.shared.loadUserAddedCourses()
        )
        reloadCurrentSemesterCourses()
        assignments = cachedAssignments

        if !merged.isEmpty {
            courses = merged
        }
        // backgroundSync() on app launch handles the network refresh
    }

    func refresh(authService: AuthService) async {
        await fetchData(authService: authService)
    }

    /// Coalesced fire-and-forget refresh. Designed for pull-to-refresh
    /// where the caller returns immediately (so UIRefreshControl dismisses
    /// its spinner) and the actual fetch continues on a detached Task.
    /// Repeated pulls while a refresh is already in flight are dropped to
    /// prevent two fetches racing on the same caches.
    func triggerRefresh(authService: AuthService) {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            await self.fetchData(authService: authService)
            let latestSemester = CourseSelectionService.currentSemesterCode()
            if latestSemester != self.currentSemester {
                let latestCourses = await AppServiceBridge.fetchCourses(
                    authService: authService,
                    semester: latestSemester
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let userAdded = DataCache.shared.loadUserAddedCourses()
                    self.currentSemesterCourses = self.buildCourseList(latestCourses, userAdded)
                    self.refreshCourseColors()
                }
            }
            await MainActor.run { [weak self] in
                self?.isRefreshing = false
            }
        }
    }

    private func fetchData(authService: AuthService) async {
        let manager = NTUSTSessionManager.shared
        let targetSemester = currentSemester
        await MainActor.run { manager.loadingState = .loading }

        // ClassTable pull-to-refresh is the explicit "show me the
        // latest enrolment" gesture — bust the CourseService cache so
        // add/drop shows up immediately instead of waiting out the 24h
        // TTL that absorbs cheaper background refreshes.
        async let coursesTask = AppServiceBridge.fetchCourses(
            authService: authService,
            semester: targetSemester,
            forceRefresh: true,
        )
        async let assignmentsTask = AppServiceBridge.fetchAssignments(authService: authService)

        let fetchedCourses = await coursesTask
        let fetchedAssignments = await assignmentsTask

        let userAdded = DataCache.shared.loadUserAddedCourses()

        await MainActor.run {
            isUpdatingFromNetwork = true
            courses = buildCourseList(fetchedCourses, userAdded)
            if targetSemester == CourseSelectionService.currentSemesterCode() {
                currentSemesterCourses = courses
                refreshCourseColors()
            }
            assignments = fetchedAssignments
            manager.loadingState = .loaded
            NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
            isUpdatingFromNetwork = false
        }
    }
}
