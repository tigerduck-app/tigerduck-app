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
            // A term picked on someone else's class table is not the user's pick.
            if !isFollowingNewestSemester, shownPerson == nil {
                Defaults[.classTableSelectedSemester] = currentSemester
            }
            reloadFromCache()
        }
    }

    /// Set while the table moves the selection itself, to the newest term or to the term another
    /// class table opens on, so that assignment doesn't get recorded as a user pick.
    private var isFollowingNewestSemester = false

    /// Re-read once `SemesterCatalog.refresh()` lands, so a term the school
    /// publishes ahead of the month heuristic (115-1 opened weeks before the
    /// heuristic rolled off 114-2) becomes selectable in the same session.
    private(set) var ownSemesters: [String] = ClassTableViewModel.semesterOptions(
        including: SemesterCatalog.selectedSemester(
            storedPick: Defaults[.classTableSelectedSemester]
        )
    )

    /// The picker's terms: the user's, or only the ones another person shared.
    var availableSemesters: [String] {
        shownPerson?.semesters ?? ownSemesters
    }

    /// Whose class table this is, nil for the user's own. Another person's is read-only, and
    /// nothing of the user's, such as assignments or Moodle, is shown on it.
    ///
    /// It moves to the store's choice only in `showShownTable()`, with the courses, so the page
    /// redraws a switch once. The store's copy carries a rename; a deleted person stays until then.
    var shownPerson: ImportedPerson? {
        guard let displayedPerson else { return nil }
        return importedTables.people.first { $0.id == displayedPerson.id } ?? displayedPerson
    }

    private var displayedPerson: ImportedPerson?

    @ObservationIgnored let importedTables: ImportedClassTableStore

    /// Looks one term of an imported class table up again: a course it cannot find keeps its row
    /// in `current`, and nil means no lookup went through.
    typealias ImportedTermLookup = @MainActor (
        _ semester: String, _ courseNos: [String], _ current: [SDCourse]
    ) async -> [SDCourse]?

    @ObservationIgnored private let lookUpImportedTerm: ImportedTermLookup

    /// Keeps the persisted selection selectable even after it ages out of the
    /// catalogue window — a `Picker` whose tag matches no option renders blank.
    private static func semesterOptions(including selected: String) -> [String] {
        let options = SemesterCatalog.availableSemesters()
        return options.contains(selected) ? options : options + [selected]
    }

    /// The catalogue can land after `init` on a cold launch, and refreshes while
    /// the app runs, so re-apply the "never picked → newest term" rule each time.
    /// Returns whether it moved the table, which reloaded it.
    @discardableResult
    private func followNewestSemesterIfUnpicked() -> Bool {
        guard shownPerson == nil,
              Defaults[.classTableSelectedSemester] == nil,
              let newest = SemesterCatalog.availableSemesters().first,
              newest != currentSemester else { return false }
        isFollowingNewestSemester = true
        currentSemester = newest
        isFollowingNewestSemester = false
        return true
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
            // The term on screen is someone else's then; the user's list gets theirs on the way back.
            if self.shownPerson == nil {
                self.ownSemesters = Self.semesterOptions(including: self.currentSemester)
            }
            self.reloadCurrentSemesterCourses()
        }
    }

    /// Silent background refresh for the currently-selected semester.
    /// Fires after the user picks a new semester from the dropdown so the
    /// cached snapshot we just rendered gets reconciled with the latest
    /// server state without blocking UI.
    func refreshSelectedSemester(authService: AuthService) async {
        guard shownPerson == nil else { return }
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
            if self.shownPerson == nil,
               merged.map(\.courseNo).sorted() != self.courses.map(\.courseNo).sorted() {
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
    /// `CourseTombstone` keys of the courses whose assignments are all ignored.
    var ignoredAssignmentCourses: Set<String> = []

    /// The course API language tag ("zh" or "en") derived from the
    /// current app language setting. Used as the locale key when
    /// reading/writing per-locale custom course names.
    var currentLocale: String {
        LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage])
    }

    /// weekday → period ID → [SDCourse]. A list so the grid can show a
    /// schedule conflict; one course per slot would silently overwrite the
    /// second. Order matches the `courses` array so conflict role assignment
    /// (A vs B) is stable.
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
    // `nonisolated(unsafe)` lets `deinit`, nonisolated even on a `@MainActor`
    // class, read these to remove the observers. Without `@ObservationIgnored`
    // the `@Observable` macro makes the storage computed and strips the modifier.
    @ObservationIgnored
    private nonisolated(unsafe) var dataObserver: Any?
    @ObservationIgnored
    private nonisolated(unsafe) var languageObserver: Any?
    @ObservationIgnored
    private nonisolated(unsafe) var holidayObserver: Any?
    /// Bumped on a "still have class" toggle, which `isClassDay` reads where Observation
    /// cannot see it.
    private var classDayRevision = 0

    /// Mirrors `Defaults[.alwaysShowAllPeriods]`. `activePeriods` has to read
    /// this rather than the key directly: a raw `Defaults` read registers no
    /// SwiftUI dependency, so flipping the toggle left the grid on its old
    /// row set until something else forced a reload.
    private(set) var showsAllPeriods: Bool = Defaults[.alwaysShowAllPeriods]
    @ObservationIgnored
    private nonisolated(unsafe) var periodVisibilityTask: Task<Void, Never>?

    /// Guards the fire-and-forget pull-to-refresh path against overlapping
    /// fetches. ``triggerRefresh(authService:)`` flips this to `true` while
    /// a fetch is running; additional pulls within that window coalesce
    /// into a no-op instead of stacking concurrent Tasks that would race
    /// on DataCache writes and `dataDidUpdate` notifications.
    var isRefreshing = false
    /// Terms with a reset in progress — see `resetCourses`.
    var resettingSemesters: Set<String> = []
    var currentSemesterCourses: [SDCourse] = []
    private let courseProvider = CanonicalCourseProvider()
    /// Whether a day is a class day — `ClassTableView` passes the school
    /// calendar's answer: in term, and not a holiday the user has left
    /// quiet. Every day, by default, so a test does not read the device's
    /// cached calendar.
    private let isClassDay: (Date) -> Bool

    init(
        isClassDay: @escaping (Date) -> Bool = { _ in true },
        importedTables: ImportedClassTableStore = .shared,
        lookUpImportedTerm: @escaping ImportedTermLookup = {
            await AppServiceBridge.refreshImportedCourses(semester: $0, courseNos: $1, current: $2)
        }
    ) {
        self.isClassDay = isClassDay
        self.importedTables = importedTables
        self.lookUpImportedTerm = lookUpImportedTerm
        displayedPerson = importedTables.shownPerson
        deletedCourseNos = Set(DataCache.shared.loadDeletedCourseNos())
        courseCustomNames = DataCache.shared.loadCourseCustomNames()
        ignoredAssignmentCourses = DataCache.shared.loadIgnoredAssignmentCourses()

        dataObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.dataDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, but the closure is `@Sendable`; hop to
            // the main actor explicitly so touching `isUpdatingFromNetwork` and
            // calling `reloadFromCache` is sound under strict concurrency.
            Task { @MainActor [weak self] in
                guard let self, !self.isUpdatingFromNetwork else { return }
                self.reloadFromCache()
            }
        }

        // Invalidate with the mirror: `cellRoleCache` is keyed by index into
        // `activePeriods`, so a new row set points every entry at the wrong period.
        // `initial: true` so a write made before this task subscribes is not lost.
        periodVisibilityTask = Task { [weak self] in
            for await value in Defaults.updates(.alwaysShowAllPeriods, initial: true) {
                guard let self else { return }
                guard value != self.showsAllPeriods else { continue }
                self.showsAllPeriods = value
                self.invalidateCellRoleCache()
            }
        }

        holidayObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.holidayNotifyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.classDayRevision &+= 1 }
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
        periodVisibilityTask?.cancel()
        if let observer = dataObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = languageObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = holidayObserver {
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
        // Someone else's courses stay as shared: the user's tombstones and custom names are keyed
        // by course number alone and would hide or rename theirs.
        if let shownPerson {
            courses = shownPerson.courses(in: currentSemester)
            return
        }
        // A term published while the app runs reaches the picker here.
        guard !followNewestSemesterIfUnpicked() else { return }
        ownSemesters = Self.semesterOptions(including: currentSemester)
        // Re-read the per-user customizations on every reload: logout deletes
        // their files and posts dataDidUpdate, and a copy read once at init
        // would apply the last account's deletions and renames to the next user.
        deletedCourseNos = Set(DataCache.shared.loadDeletedCourseNos())
        courseCustomNames = DataCache.shared.loadCourseCustomNames()
        ignoredAssignmentCourses = DataCache.shared.loadIgnoredAssignmentCourses()
        TigerDuckTheme.reload()
        reloadCurrentSemesterCourses()
        courses = buildCourseList(
            DataCache.shared.loadCourses(semester: currentSemester),
            DataCache.shared.loadUserAddedCourses(semester: currentSemester)
        )
        assignments = DataCache.shared.loadAssignments()
    }

    /// Whose class table shows and which version of it, for `showShownTable()` to follow.
    var shownTable: ImportedClassTableStore.ShownTable { importedTables.shownTable }

    /// Moves the table to whoever `importedTables` shows now. Someone else's keeps the term on
    /// screen when they shared it and otherwise opens on their latest term; the user's own opens
    /// on its own term, as at launch.
    func showShownTable() {
        displayedPerson = importedTables.shownPerson
        if shownPerson != nil {
            // Another window can switch class tables while one of the user's own edits is open
            // here, and it must not save into someone else's.
            showAddCourse = false
            showResetConfirm = false
            showRenameAlert = false
            courseToRename = nil
            courseToRecolor = nil
        }
        let semester = shownPerson?.semester(keeping: currentSemester)
            ?? SemesterCatalog.selectedSemester(storedPick: Defaults[.classTableSelectedSemester])
        guard semester != currentSemester else {
            reloadFromCache()
            return
        }
        isFollowingNewestSemester = true
        currentSemester = semester
        isFollowingNewestSemester = false
    }

    var isRenamingPerson = false
    var nicknameDraft = ""
    var isDeletingPerson = false
    /// The person the open rename or delete alert names. Another window can switch class tables
    /// while one is up, so the alert acts on this person, not on whoever shows then.
    private(set) var personInAlert: ImportedPerson?
    var showsLookupFailed = false
    var showsSaveFailed = false
    private(set) var isRefreshingShownPerson = false

    /// The store keeps no blank nickname, so Save waits for one.
    var canSaveNickname: Bool {
        !nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func startRenamingPerson() {
        guard let shownPerson else { return }
        personInAlert = shownPerson
        nicknameDraft = shownPerson.nickname
        isRenamingPerson = true
    }

    func saveNickname() {
        guard let personInAlert else { return }
        if importedTables.rename(personInAlert.id, to: nicknameDraft) == .failed { showsSaveFailed = true }
    }

    func startDeletingPerson() {
        guard let shownPerson else { return }
        personInAlert = shownPerson
        isDeletingPerson = true
    }

    /// Deleting the shown person shows the user's own class table again, through the class table
    /// page following the store as for any other switch.
    func deletePersonInAlert() {
        guard let personInAlert else { return }
        if importedTables.delete(personInAlert.id) == .failed { showsSaveFailed = true }
    }

    /// Pull to refresh on someone else's class table: looks the term on screen up again, and says
    /// so when no lookup went through.
    func refreshShownPerson() async {
        guard !isRefreshingShownPerson, let person = shownPerson,
              let term = person.terms.first(where: { $0.semester == currentSemester }) else { return }
        isRefreshingShownPerson = true
        defer { isRefreshingShownPerson = false }
        guard let refreshed = await lookUpImportedTerm(term.semester, term.courseNos, term.courses) else {
            showsLookupFailed = true
            return
        }
        let change = importedTables.updateCourses(
            person.id, semester: term.semester, courseNos: term.courseNos, courses: refreshed,
            importedAt: person.importedAt
        )
        if change == .failed { showsSaveFailed = true }
        if shownPerson?.id == person.id { reloadFromCache() }
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
    /// inside is O(span), so caching keeps re-renders cheap. Not observed: the
    /// grid fills it while its body runs, and a tracked write would redraw it.
    @ObservationIgnored
    var cellRoleCache: [CellRoleKey: CellRole] = [:]

    struct CellRoleKey: Hashable {
        let weekday: Int
        let periodIndex: Int
    }

    func reloadCurrentSemesterCourses() {
        currentSemesterCourses = courseProvider.currentCourses()
    }

    /// Someone else's courses keep the colour their course number hashes to: an assigned one is
    /// saved with the user's and would take one of the palette's colours from the user's courses.
    func refreshCourseColors() {
        let shown = shownPerson == nil ? courses.map(\.courseNo) : []
        let courseNos = Set(shown).union(currentSemesterCourses.map(\.courseNo))
        TigerDuckTheme.ensureAssignments(courseNos: Array(courseNos))
    }

    var totalCredits: Double {
        courses.reduce(0) { $0 + $1.credits }
    }

    var selectedCourseTimeRange: String? {
        if let override = selectedCourseBlockTimeRange { return override }
        guard let course = selectedCourse, let weekday = selectedWeekday else { return nil }
        return course.timeRange(for: weekday)
    }

    var todayCourses: [SDCourse] {
        // The carousel is the user's own day, which would read as the other person's.
        guard shownPerson == nil else { return [] }
        // Observation can't track `AppClock.now()` (`AppClock` is an enum) inside
        // `coursesForToday()`, so reading `AppClockState.shared.version` here keeps
        // SwiftUI aware of debug time-override flips.
        _ = AppClockState.shared.version
        _ = minuteTicker.tick
        _ = classDayRevision
        // Empty outside the term, where the carousel would show a stale day, and on a
        // holiday the user has not opted back into, as the Live Activity and widgets do.
        guard isClassDay(AppClock.now()) else { return [] }
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

    /// Re-publishes minute-of-day-derived state when the minute changes,
    /// checked every 5 seconds like Android's `_currentDayTime` poll, so the
    /// "Current class" card slides into view within a few seconds of the
    /// wall-clock minute boundary, not up to a minute later.
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
        // Pinned rather than merged into `defaultVisible` so the widget
        // and any other grid keep their own, tighter default — five empty
        // rows cost far more in a widget than on a full page.
        if showsAllPeriods {
            periodIds.formUnion(AppConstants.Periods.chronologicalOrder)
        }
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

    /// The user's assignments, so none on someone else's class table, even for a course both take.
    func hasAssignment(for courseNo: String) -> Bool {
        shownPerson == nil && assignments.hasUnfinished(for: courseNo)
    }

    func assignmentsFor(courseNo: String) -> [SDAssignment] {
        shownPerson == nil ? assignments.unfinished(for: courseNo) : []
    }

    func ignoresAssignments(of courseNo: String) -> Bool {
        shownPerson == nil
            && ignoredAssignmentCourses.contains(CourseTombstone.key(semester: currentSemester, courseNo: courseNo))
    }

    /// Assignments are fetched for `CourseSelectionService.currentSemesterCode()` alone, so only
    /// that term's courses can have theirs ignored.
    var offersIgnoreAssignments: Bool {
        shownPerson == nil && currentSemester == CourseSelectionService.currentSemesterCode()
    }

    var onSyncCourseIgnore: ((_ course: SDCourse, _ semester: String, _ ignore: Bool) -> Void)?
    var onSyncCourseOverride: ((_ moodleCourseId: String, _ colorHex: String?, _ customName: String?, _ locale: String?) -> Void)?
    var onSyncColorPick: ((_ hex: UInt32, _ course: SDCourse, _ changed: [String: UInt32]) -> Void)?
    var onCoursesChanged: ((_ courses: [SDCourse], _ semester: String) -> Void)?
    var onCourseAdded: ((_ courses: [SDCourse], _ semester: String, _ addedCourseNo: String) -> Void)?
    var onCourseDeleted: ((_ courseNo: String, _ semester: String) -> Void)?
    /// Wipes the backend for the term and, on success only, runs the local
    /// wipe it is handed — see `AppState.deleteBackendCourses`.
    var onResetBackendCourses: ((_ semester: String, _ resetLocally: @MainActor () -> Void) async -> Bool)?
}
