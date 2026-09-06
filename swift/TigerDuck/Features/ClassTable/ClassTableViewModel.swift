import Defaults
import SwiftUI

/// `@MainActor` so the `MinuteTicker` stored property (a `@MainActor`
/// type) can be constructed in the initializer, and so notification
/// observer callbacks that mutate `@Observable` state aren't racing
/// SwiftUI reads. Mirrors `CalendarViewModel` / `ScoreViewModel`.
@MainActor
@Observable
final class ClassTableViewModel {
    var courses: [SDCourse] = [] {
        didSet { rebuildLookup() }
    }
    var assignments: [SDAssignment] = []
    var selectedCourse: SDCourse? = nil

    var selectedWeekday: Int? = nil
    var selectedPeriodId: String? = nil
    /// Explicit time-range string for the detail sheet, set when the
    /// caller knows the precise block (e.g. an `OngoingCourseInfo`
    /// carousel card whose period block is a strict subset of the
    /// day's schedule). Takes precedence over `course.timeRange(for:)`
    /// in `selectedCourseTimeRange` so split same-day periods don't
    /// collapse into a single whole-day span. Cleared by every other
    /// selection entry point.
    var selectedCourseBlockTimeRange: String? = nil

    var currentSemester: String = SemesterCatalog.selectedSemester(
        storedPick: Defaults[.classTableSelectedSemester]
    ) {
        didSet {
            guard currentSemester != oldValue else { return }
            if !isFollowingNewestSemester {
                Defaults[.classTableSelectedSemester] = currentSemester
            }
            reloadFromCache()
        }
    }

    /// Set only while `followNewestSemesterIfUnpicked()` moves the selection,
    /// so that assignment doesn't get recorded as a user pick.
    private var isFollowingNewestSemester = false

    /// Re-read once `SemesterCatalog.refresh()` lands, so a term the school
    /// publishes ahead of the month heuristic (115-1 opened weeks before the
    /// heuristic rolled off 114-2) becomes selectable in the same session.
    private(set) var availableSemesters: [String] = ClassTableViewModel.semesterOptions(
        including: SemesterCatalog.selectedSemester(
            storedPick: Defaults[.classTableSelectedSemester]
        )
    )

    /// Keeps the persisted selection selectable even after it ages out of the
    /// catalogue window — a `Picker` whose tag matches no option renders blank.
    private static func semesterOptions(including selected: String) -> [String] {
        let options = SemesterCatalog.availableSemesters()
        return options.contains(selected) ? options : options + [selected]
    }

    /// The catalogue can land after `init` on a cold launch, so re-apply the
    /// "never picked → newest term" rule once it does.
    private func followNewestSemesterIfUnpicked() {
        guard Defaults[.classTableSelectedSemester] == nil,
              let newest = SemesterCatalog.availableSemesters().first,
              newest != currentSemester else { return }
        isFollowingNewestSemester = true
        currentSemester = newest
        isFollowingNewestSemester = false
    }

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
            guard let self else { return }
            self.followNewestSemesterIfUnpicked()
            self.availableSemesters = Self.semesterOptions(including: self.currentSemester)
            self.reloadCurrentSemesterCourses()
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
            let userAdded = DataCache.shared.loadUserAddedCourses(semester: target)
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
    var showResetConfirm = false
    var showResetFailedAlert = false
    var courseToRename: SDCourse? = nil
    var renameText: String = ""
    var showRenameAlert = false

    /// Non-nil while the color picker sheet is presented. SwiftUI's
    /// `sheet(item:)` binding drives both presentation and dismissal, so
    /// setting this to nil closes the sheet.
    var courseToRecolor: SDCourse? = nil

    var deletedCourseNos: Set<String> = []
    var courseCustomNames: [String: [String: String]] = [:]

    /// The course API language tag ("zh" or "en") derived from the
    /// current app language setting. Used as the locale key when
    /// reading/writing per-locale custom course names.
    var currentLocale: String {
        LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage])
    }

    /// weekday → period ID → [SDCourse]. A list (not single) so the grid can
    /// surface 衝堂 (conflict) instead of the previous behaviour where the
    /// second course in a slot was silently overwritten. Order matches the
    /// `courses` array so conflict role-assignment (A vs B) is stable.
    private var courseLookup: [Int: [String: [SDCourse]]] = [:]

    /// Cell-tap state when the user taps a conflict cell. The grid view
    /// presents a picker sheet driven by this; selecting one route through
    /// `selectCourse` and clears it.
    var conflictPickerTarget: ConflictPickerTarget? = nil

    /// Set when an add would push a slot to 3+ overlapping courses. Drives
    /// an alert in ``ClassTableView``.
    var tripleConflictError: TripleConflictError? = nil

    var hasLoaded = false
    var isUpdatingFromNetwork = false
    // `nonisolated(unsafe)` so `deinit` (which runs nonisolated even on a
    // `@MainActor` class) can read these to remove the observers at end-
    // of-life. `@ObservationIgnored` is required for the isolation
    // modifier to take effect — without it the `@Observable` macro
    // replaces the storage with a computed accessor and strips the
    // modifier. Same pattern as `CalendarViewModel.dataObserver`.
    @ObservationIgnored
    private nonisolated(unsafe) var dataObserver: Any?
    @ObservationIgnored
    private nonisolated(unsafe) var languageObserver: Any?

    /// Guards the fire-and-forget pull-to-refresh path against overlapping
    /// fetches. ``triggerRefresh(authService:)`` flips this to `true` while
    /// a fetch is running; additional pulls within that window coalesce
    /// into a no-op instead of stacking concurrent Tasks that would race
    /// on DataCache writes and `dataDidUpdate` notifications.
    var isRefreshing = false
    var currentSemesterCourses: [SDCourse] = []
    private let courseProvider = CanonicalCourseProvider()

    init() {
        deletedCourseNos = Set(DataCache.shared.loadDeletedCourseNos())
        courseCustomNames = DataCache.shared.loadCourseCustomNames()

        dataObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.dataDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Notification is delivered on the main queue, but the closure
            // is `@Sendable` and crosses into a `@MainActor` class — hop
            // explicitly so accessing `isUpdatingFromNetwork` / calling
            // `reloadFromCache` is sound under strict concurrency.
            Task { @MainActor [weak self] in
                guard let self, !self.isUpdatingFromNetwork else { return }
                self.reloadFromCache()
            }
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

    func mergeWithUserAdded(_ primary: [SDCourse], _ userAdded: [SDCourse]) -> [SDCourse] {
        var merged = primary
        for course in userAdded {
            if !merged.contains(where: { $0.courseNo == course.courseNo }) {
                merged.append(course)
            }
        }
        return merged
    }

    func buildCourseList(_ primary: [SDCourse], _ userAdded: [SDCourse]) -> [SDCourse] {
        var merged = mergeWithUserAdded(primary, userAdded)
        applyCustomizations(&merged)
        return merged
    }

    func reloadFromCache() {
        // Re-read the per-user customization sets from disk on every reload
        // so that a logout (which deletes the backing files and posts
        // dataDidUpdate) actually clears the in-memory state. Loading from
        // disk just once at init left the previous account's deletions and
        // renames applied to the next user's class table for the rest of
        // the app session.
        deletedCourseNos = Set(DataCache.shared.loadDeletedCourseNos())
        courseCustomNames = DataCache.shared.loadCourseCustomNames()
        TigerDuckTheme.reload()
        reloadCurrentSemesterCourses()
        courses = buildCourseList(
            DataCache.shared.loadCourses(semester: currentSemester),
            DataCache.shared.loadUserAddedCourses(semester: currentSemester)
        )
        assignments = DataCache.shared.loadAssignments()
    }

    func rebuildLookup() {
        var lookup: [Int: [String: [SDCourse]]] = [:]
        // Walk `courses` in order so the same (weekday, period) always yields
        // the same A/B ordering across renders.
        for course in courses {
            for (weekday, periods) in course.schedule {
                for period in periods {
                    lookup[weekday, default: [:]][period, default: []].append(course)
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
    var cellRoleCache: [CellRoleKey: CellRole] = [:]

    struct CellRoleKey: Hashable {
        let weekday: Int
        let periodIndex: Int
    }

    func reloadCurrentSemesterCourses() {
        currentSemesterCourses = courseProvider.currentCourses()
    }

    func refreshCourseColors() {
        let courseNos = Set(courses.map(\.courseNo)).union(currentSemesterCourses.map(\.courseNo))
        TigerDuckTheme.ensureAssignments(courseNos: Array(courseNos))
    }

    var totalCredits: Int {
        courses.reduce(0) { $0 + $1.credits }
    }

    var selectedCourseTimeRange: String? {
        if let override = selectedCourseBlockTimeRange { return override }
        guard let course = selectedCourse, let weekday = selectedWeekday else { return nil }
        return course.timeRange(for: weekday)
    }

    var todayCourses: [SDCourse] {
        // `coursesForToday()` reads `AppClock.now()`, which Observation
        // can't track because `AppClock` is an enum. Pulling
        // `AppClockState.shared.version` into the read keeps SwiftUI
        // dependency tracking aware of debug-time-override flips.
        _ = AppClockState.shared.version
        _ = minuteTicker.tick
        // ponytail: outside the term there is no "today" worth showing —
        // the carousel would either be empty or surface a stale day. Empty
        // here also hides the section, which keys off `todayCourses.isEmpty`.
        guard AppConstants.CurrentTerm.isInSession else { return [] }
        return currentSemesterCourses.coursesForToday()
    }

    /// Courses whose contiguous period block contains the current
    /// minute-of-day. Drives the leftmost "Current class" cards in the
    /// today carousel (matches Android's `ongoingCourses`).
    var ongoingCourses: [OngoingCourseInfo] {
        _ = AppClockState.shared.version
        _ = minuteTicker.tick
        let now = AppClock.now()
        let cal = AppConstants.taipeiCalendar
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return currentSemesterCourses.ongoingCourses(
            weekday: now.scheduleWeekday,
            minuteOfDay: minuteOfDay
        )
    }

    /// 5-second ticker that re-publishes minute-of-day-derived state.
    /// Matches Android's `_currentDayTime` poll so the "Current class"
    /// card slides into view within a few seconds of the wall-clock
    /// minute boundary, not up to a minute later.
    @ObservationIgnored
    private let minuteTicker = MinuteTicker()

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
        courseLookup[weekday]?[period]?.first
    }

    /// All courses present in a given slot. Up to 2 are rendered as a
    /// conflict cell; the algorithm guards against 3+ at add time.
    func courses(for weekday: Int, period: String) -> [SDCourse] {
        courseLookup[weekday]?[period] ?? []
    }

    func hasAssignment(for courseNo: String) -> Bool {
        assignments.hasUnfinished(for: courseNo)
    }

    func assignmentsFor(courseNo: String) -> [SDAssignment] {
        assignments.unfinished(for: courseNo)
    }

    var onSyncCourseOverride: ((_ moodleCourseId: String, _ colorHex: String?, _ customName: String?, _ locale: String?) -> Void)?
    var onCoursesChanged: ((_ courses: [SDCourse], _ semester: String) -> Void)?
    var onCourseAdded: ((_ courses: [SDCourse], _ semester: String, _ addedCourseNo: String) -> Void)?
    var onCourseDeleted: ((_ courseNo: String, _ semester: String) -> Void)?
    var onResetBackendCourses: ((_ semester: String) async -> Bool)?
}
