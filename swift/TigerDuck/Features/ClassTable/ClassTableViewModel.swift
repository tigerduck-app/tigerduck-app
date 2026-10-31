import Defaults
import SwiftUI
import TigerDuckCore

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
    var selectedCoursePeriods: [String]? = nil
    var selectedDate: Date? = nil
    /// The running class the Current class card opened, which can be one piece of its meeting.
    var selectedSlot: CourseTimeSlot? = nil
    var courseChanges: CourseChanges = .cached

    var currentSemester: String = SemesterCatalog.selectedSemester(
        storedPick: Defaults[.classTableSelectedSemester]
    ) {
        didSet {
            guard currentSemester != oldValue else { return }
            if !isFollowingNewestSemester, shownPerson == nil {
                Defaults[.classTableSelectedSemester] = currentSemester
            }
            reloadFromCache()
        }
    }

    private var isFollowingNewestSemester = false

    private(set) var ownSemesters: [String] = ClassTableViewModel.semesterOptions(
        including: SemesterCatalog.selectedSemester(
            storedPick: Defaults[.classTableSelectedSemester]
        )
    )

    var availableSemesters: [String] {
        shownPerson?.semesters ?? ownSemesters
    }

    var shownPerson: ImportedPerson? {
        guard let displayedPerson else { return nil }
        return importedTables.people.first { $0.id == displayedPerson.id } ?? displayedPerson
    }

    private var displayedPerson: ImportedPerson?

    @ObservationIgnored let importedTables: ImportedClassTableStore

    typealias ImportedTermLookup = @MainActor (
        _ semester: String, _ courseNos: [String], _ current: [SDCourse]
    ) async -> [SDCourse]?

    @ObservationIgnored private let lookUpImportedTerm: ImportedTermLookup

    /// Keeps the persisted selection selectable even after it ages out of the
    /// catalogue window — a `Picker` whose tag matches no option renders blank.
    static func semesterOptions(including selected: String) -> [String] {
        let options = SemesterCatalog.availableSemesters()
        return options.contains(selected) ? options : options + [selected]
    }

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

    func displayLabel(for code: String) -> String {
        AcademicTerm.label(of: code)
    }

    private var hasWarmedCaches = false

    func warmCachesIfNeeded(authService: AuthService) async {
        guard !hasWarmedCaches else { return }
        hasWarmedCaches = true
        await AppServiceBridge.warmAllSemesterCaches(authService: authService)
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.followNewestSemesterIfUnpicked()
            if self.shownPerson == nil {
                self.ownSemesters = Self.semesterOptions(including: self.currentSemester)
            }
            self.reloadCurrentSemesterCourses()
        }
    }

    func refreshSelectedSemester(authService: AuthService) async {
        guard shownPerson == nil else { return }
        let target = currentSemester
        _ = await AppServiceBridge.fetchCourses(authService: authService, semester: target)
        await MainActor.run { [weak self] in
            guard let self, self.currentSemester == target else { return }
            let merged = self.buildCourseList(
                courseStore.loadCourses(semester: target), courseStore.loadUserAddedCourses(semester: target)
            )
            if self.shownPerson == nil, Self.showsChange(merged, over: self.courses) {
                self.courses = merged
            }
            if target == CourseSelectionService.currentSemesterCode() {
                self.currentSemesterCourses = merged
                self.refreshCourseColors()
            }
        }
    }

    static func showsChange(_ fresh: [SDCourse], over shown: [SDCourse]) -> Bool {
        func drawn(_ courses: [SDCourse]) -> [DrawnCourse] {
            courses.sorted { $0.courseNo < $1.courseNo }.map(DrawnCourse.init)
        }
        return drawn(fresh) != drawn(shown)
    }

    private struct DrawnCourse: Equatable {
        let courseNo, name, customName, instructor, classroom: String
        let credits: Double
        let enrolledCount, maxCount: Int
        let schedule: [Int: [String]]
        let classroomMap: [String: String]
        let moodleIdNumber: String?
        let dimension, allYear, requireOption: String

        init(_ course: SDCourse) {
            courseNo = course.courseNo
            name = course.courseName
            customName = course.customName ?? ""
            instructor = course.instructor
            classroom = course.classroom
            credits = course.credits
            enrolledCount = course.enrolledCount
            maxCount = course.maxCount
            schedule = course.schedule
            classroomMap = course.classroomMap
            moodleIdNumber = course.moodleIdNumber
            dimension = course.dimension
            allYear = course.allYear
            requireOption = course.requireOption
        }
    }

    var showAddCourse = false
    var showResetConfirm = false
    var showResetFailedAlert = false
    var courseToRename: SDCourse? = nil
    var renameText: String = ""
    var showRenameAlert = false

    var courseToRecolor: SDCourse? = nil

    var deletedCourseNos: Set<String> = []
    var courseCustomNames: [String: [String: String]] = [:]
    var ignoredAssignmentCourses: Set<String> = []

    var currentLocale: String {
        LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage])
    }

    private var courseLookup: [Int: [String: [SDCourse]]] = [:]

    var conflictPickerTarget: ConflictPickerTarget? = nil

    var tripleConflictError: TripleConflictError? = nil

    var hasLoaded = false
    @ObservationIgnored private var storeObservation: StoreObservation?
    // `nonisolated(unsafe)` lets `deinit`, nonisolated even on a `@MainActor`
    // class, read these to remove the observers. Without `@ObservationIgnored`
    // the `@Observable` macro makes the storage computed and strips the modifier.
    @ObservationIgnored
    private nonisolated(unsafe) var languageObserver: Any?
    @ObservationIgnored
    private nonisolated(unsafe) var holidayObserver: Any?
    private var classDayRevision = 0

    private(set) var showsAllPeriods: Bool = Defaults[.alwaysShowAllPeriods]
    @ObservationIgnored
    private nonisolated(unsafe) var periodVisibilityTask: Task<Void, Never>?

    var isRefreshing = false
    var resettingSemesters: Set<String> = []
    var currentSemesterCourses: [SDCourse] = []
    private let courseProvider = CanonicalCourseProvider()
    private let isClassDay: (Date) -> Bool
    @ObservationIgnored let courseStore: CourseStore

    init(
        isClassDay: @escaping (Date) -> Bool = { _ in true },
        courses: CourseStore = .shared,
        importedTables: ImportedClassTableStore = .shared,
        lookUpImportedTerm: @escaping ImportedTermLookup = {
            await AppServiceBridge.refreshImportedCourses(semester: $0, courseNos: $1, current: $2)
        }
    ) {
        self.isClassDay = isClassDay
        courseStore = courses
        self.importedTables = importedTables
        self.lookUpImportedTerm = lookUpImportedTerm
        displayedPerson = importedTables.shownPerson
        deletedCourseNos = Set(courseStore.loadDeletedCourseNos())
        courseCustomNames = courseStore.loadCourseCustomNames()
        ignoredAssignmentCourses = AssignmentStore.shared.loadIgnoredAssignmentCourses()

        storeObservation = StoreObservation(read: { _ = AppDataRevision.current }) { [weak self] in
            self?.reloadFromCache()
        }

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
            AppServiceBridge.handleLanguageChange()
        }
    }

    deinit {
        periodVisibilityTask?.cancel()
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
        if let shownPerson {
            reloadCurrentSemesterCourses()
            courses = shownPerson.courses(in: currentSemester)
            courseChanges = .cached
            return
        }
        guard !followNewestSemesterIfUnpicked() else { return }
        ownSemesters = Self.semesterOptions(including: currentSemester)
        deletedCourseNos = Set(courseStore.loadDeletedCourseNos())
        courseCustomNames = courseStore.loadCourseCustomNames()
        ignoredAssignmentCourses = AssignmentStore.shared.loadIgnoredAssignmentCourses()
        TigerDuckTheme.reload()
        reloadCurrentSemesterCourses()
        courses = buildCourseList(
            courseStore.loadCourses(semester: currentSemester),
            courseStore.loadUserAddedCourses(semester: currentSemester)
        )
        assignments = AssignmentStore.shared.loadAssignments()
        courseChanges = .cached
    }

    var shownTable: ImportedClassTableStore.ShownTable { importedTables.shownTable }

    func closeOwnEdits() {
        showAddCourse = false
        showResetConfirm = false
        showRenameAlert = false
        courseToRename = nil
        courseToRecolor = nil
    }

    func showShownTable() {
        displayedPerson = importedTables.shownPerson
        if shownPerson != nil { closeOwnEdits() }
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
    private(set) var personInAlert: ImportedPerson?
    var showsLookupFailed = false
    var showsSaveFailed = false
    private(set) var isRefreshingShownPerson = false

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

    func deletePersonInAlert() {
        guard let personInAlert else { return }
        if importedTables.delete(personInAlert.id) == .failed { showsSaveFailed = true }
    }

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

    func invalidateCellRoleCache() {
        cellRoleCache.removeAll(keepingCapacity: true)
    }

    @ObservationIgnored
    var cellRoleCache: [CellRoleKey: CellRole] = [:]

    struct CellRoleKey: Hashable {
        let weekday: Int
        let periodIndex: Int
    }

    func reloadCurrentSemesterCourses() {
        currentSemesterCourses = courseProvider.currentCourses()
    }

    func refreshCourseColors() {
        let shown = shownPerson == nil ? courses.map(\.courseNo) : []
        let courseNos = Set(shown).union(currentSemesterCourses.map(\.courseNo))
        TigerDuckTheme.ensureAssignments(courseNos: Array(courseNos))
    }

    var totalCredits: Double {
        courses.reduce(0) { $0 + $1.credits }
    }

    var selectedCourseTimeRange: String? {
        if let periods = selectedCoursePeriods { return SDCourse.timeRange(periods: periods) }
        guard let course = selectedCourse, let weekday = selectedWeekday else { return nil }
        return course.timeRange(for: weekday)
    }

    var todayCourses: [SDCourse] {
        guard shownPerson == nil else { return [] }
        _ = AppClockState.shared.version
        _ = minuteTicker.tick
        _ = classDayRevision
        guard isClassDay(AppClock.now()) else { return [] }
        return currentSemesterCourses.coursesForToday()
    }

    var ongoingCourses: [OngoingCourseInfo] {
        _ = AppClockState.shared.version
        _ = minuteTicker.tick
        return currentSemesterCourses.ongoingCourses(at: AppClock.now(), changes: courseChanges)
    }

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

    func courses(for weekday: Int, period: String) -> [SDCourse] {
        courseLookup[weekday]?[period] ?? []
    }

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

    var offersIgnoreAssignments: Bool {
        shownPerson == nil && currentSemester == CourseSelectionService.currentSemesterCode()
    }

    var onSyncCourseIgnore: ((_ course: SDCourse, _ semester: String, _ ignore: Bool) -> Void)?
    var onSyncCourseOverride: ((_ moodleCourseId: String, _ colorHex: String?, _ customName: String?, _ locale: String?) -> Void)?
    var onSyncColorPick: ((_ hex: UInt32, _ course: SDCourse, _ changed: [String: UInt32]) -> Void)?
    var onCoursesChanged: ((_ courses: [SDCourse], _ semester: String) -> Void)?
    var onCourseAdded: ((_ courses: [SDCourse], _ semester: String, _ addedCourseNo: String) -> Void)?
    var onCourseDeleted: ((_ courseNo: String, _ semester: String) -> Void)?
    var onResetBackendCourses: ((_ semester: String, _ resetLocally: @MainActor () -> Void) async -> Bool)?
}
