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
    var showResetConfirm = false
    var courseToRename: SDCourse? = nil
    var renameText: String = ""
    var showRenameAlert = false

    /// Non-nil while the color picker sheet is presented. SwiftUI's
    /// `sheet(item:)` binding drives both presentation and dismissal, so
    /// setting this to nil closes the sheet.
    var courseToRecolor: SDCourse? = nil

    private var deletedCourseNos: Set<String> = []
    private var courseCustomNames: [String: [String: String]] = [:]

    /// The course API language tag ("zh" or "en") derived from the
    /// current app language setting. Used as the locale key when
    /// reading/writing per-locale custom course names.
    private var currentLocale: String {
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

    private var hasLoaded = false
    private var isUpdatingFromNetwork = false
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
        TigerDuckTheme.reload()
        reloadCurrentSemesterCourses()
        courses = buildCourseList(
            DataCache.shared.loadCourses(semester: currentSemester),
            DataCache.shared.loadUserAddedCourses()
        )
        assignments = DataCache.shared.loadAssignments()
    }

    private func rebuildLookup() {
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

    struct ConflictSegment: Equatable {
        let course: SDCourse
        /// Contiguous block length in rows.
        let span: Int
        /// 0-indexed row offset from the cluster's `clusterStart` where
        /// this course's block begins.
        let offset: Int
    }

    enum CellRole {
        case empty
        case solo(SDCourse, spanCount: Int)
        /// Two or more overlapping courses sharing a cluster.
        /// `combinedSpan` is the total row count of the union of every
        /// segment's block; each segment's `offset` / `span` place it
        /// inside that union. The renderer keeps the L-split layout for
        /// the 2-course case and falls back to a column layout when a
        /// chain pulls in 3+ courses (so every scheduled period stays
        /// visible — no row gets buried under a `.skip` with nothing
        /// drawn on top).
        case conflictStart(segments: [ConflictSegment], combinedSpan: Int)
        /// This cell is part of a SoloStart / ConflictStart cluster that
        /// began at an earlier row; the renderer must emit nothing here so
        /// the parent's `combinedSpan` overlay can occupy the rows.
        case skip
    }

    /// Walks backward and forward from `startIndex` through `activePeriods`,
    /// collecting the contiguous block where `course` is present. Returns
    /// (firstIndex, span). Used by the conflict-cluster algorithm so block
    /// extents are computed against the same chronological ordering the
    /// grid renders.
    private func blockFor(weekday: Int, startIndex: Int, course: SDCourse) -> (first: Int, span: Int) {
        let periods = activePeriods
        let courseNo = course.courseNo

        var first = startIndex
        while first - 1 >= 0 {
            let prev = periods[first - 1]
            let present = courses(for: weekday, period: prev.id).contains { $0.courseNo == courseNo }
            if present { first -= 1 } else { break }
        }
        var last = startIndex
        while last + 1 < periods.count {
            let next = periods[last + 1]
            let present = courses(for: weekday, period: next.id).contains { $0.courseNo == courseNo }
            if present { last += 1 } else { break }
        }
        return (first, last - first + 1)
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
        let coursesHere = courses(for: weekday, period: period.id)
        if coursesHere.isEmpty {
            cellRoleCache[key] = .empty
            return .empty
        }

        // Build transitive closure of courses whose blocks overlap with any
        // course already in the cluster, rooted at the courses present in
        // this cell. This guarantees we emit a `conflictStart` at the
        // earliest row of the union and `.skip` thereafter.
        var closure: [(course: SDCourse, first: Int, span: Int)] = []
        var seen: Set<String> = []

        func addCourse(_ c: SDCourse, seedIndex: Int) {
            if !seen.insert(c.courseNo).inserted { return }
            let block = blockFor(weekday: weekday, startIndex: seedIndex, course: c)
            closure.append((c, block.first, block.span))
            for i in block.first..<(block.first + block.span) {
                guard let pid = periods[safe: i]?.id else { continue }
                for other in courses(for: weekday, period: pid) where !seen.contains(other.courseNo) {
                    addCourse(other, seedIndex: i)
                }
            }
        }
        for c in coursesHere { addCourse(c, seedIndex: periodIndex) }

        let clusterStart = closure.map(\.first).min() ?? periodIndex

        if clusterStart < periodIndex {
            cellRoleCache[key] = .skip
            return .skip
        }

        if closure.count == 1 {
            let only = closure[0]
            let role = CellRole.solo(only.course, spanCount: only.span)
            cellRoleCache[key] = role
            return role
        }

        // Emit a segment per course in the closure so a 3+ chain
        // (e.g. A on periods 1-2, B on 2-3, C on 3-4) keeps every
        // scheduled period visible. Earlier code capped the cluster at
        // two segments, which left the third course's tail covered by
        // `.skip` but not drawn over — hiding scheduled class time.
        // Anchored-slot courses lead the array so the rendering order
        // matches the cell the user tapped; the rest follow in
        // closure-insertion order.
        let anchoredNos = Set(coursesHere.map(\.courseNo))
        let anchoredFirst = closure.filter { anchoredNos.contains($0.course.courseNo) }
        let rest = closure.filter { !anchoredNos.contains($0.course.courseNo) }
        let ordered = anchoredFirst + rest
        let segments = ordered.map { entry in
            ConflictSegment(
                course: entry.course,
                span: entry.span,
                offset: entry.first - clusterStart
            )
        }
        let clusterEnd = closure.map { $0.first + $0.span }.max() ?? periodIndex
        let role = CellRole.conflictStart(
            segments: segments,
            combinedSpan: clusterEnd - clusterStart
        )
        cellRoleCache[key] = role
        return role
    }

    struct ConflictPickerTarget: Identifiable {
        let id = UUID()
        let courses: [SDCourse]
        let weekday: Int
        let periodId: String
    }

    struct TripleConflictError: Identifiable {
        let id = UUID()
        let weekday: Int
        let periodId: String
        let newCourseName: String
        let existingA: SDCourse
        let existingB: SDCourse
    }

    /// Scans every slot the candidate would occupy and returns the first
    /// slot that already has two courses — adding the candidate there would
    /// push it to three. Returns nil when the add is safe.
    func wouldCauseTripleConflict(_ candidate: SDCourse) -> TripleConflictError? {
        for (weekday, periodIds) in candidate.schedule {
            for pid in periodIds {
                let existing = courses(for: weekday, period: pid)
                if existing.count >= 2 {
                    return TripleConflictError(
                        weekday: weekday,
                        periodId: pid,
                        newCourseName: candidate.displayName,
                        existingA: existing[0],
                        existingB: existing[1]
                    )
                }
            }
        }
        return nil
    }

    func presentConflictPicker(courseA: SDCourse, courseB: SDCourse, weekday: Int, periodId: String) {
        // Surface every course in the cluster's transitive closure — the
        // L-render is capped at two courses, but a 3+ chain (e.g. A+C
        // anchored here and A+B at the next period) must keep all of
        // them reachable through the picker so the third never becomes
        // unselectable.
        var resolved = conflictClosureCourses(weekday: weekday, periodId: periodId)
        if resolved.isEmpty {
            resolved = [courseA, courseB]
        } else {
            // Guarantee the two displayed courses lead the list — the
            // picker rows then match the L cluster the user just tapped.
            let displayed = [courseA, courseB]
            let displayedNos = Set(displayed.map(\.courseNo))
            resolved = displayed + resolved.filter { !displayedNos.contains($0.courseNo) }
        }
        conflictPickerTarget = ConflictPickerTarget(
            courses: resolved,
            weekday: weekday,
            periodId: periodId
        )
    }

    /// Walk the same transitive-closure logic `cellRole` uses, but return
    /// the full list of courses involved in the conflict cluster anchored
    /// at `(weekday, periodId)`. Used by the picker so a 3+ course chain
    /// surfaces every course, even though the L-cluster only renders two.
    private func conflictClosureCourses(weekday: Int, periodId: String) -> [SDCourse] {
        let periods = activePeriods
        guard let periodIndex = periods.firstIndex(where: { $0.id == periodId }) else {
            return []
        }
        var resolved: [SDCourse] = []
        var seen: Set<String> = []
        func add(_ c: SDCourse, seedIndex: Int) {
            guard seen.insert(c.courseNo).inserted else { return }
            resolved.append(c)
            let block = blockFor(weekday: weekday, startIndex: seedIndex, course: c)
            for i in block.first..<(block.first + block.span) {
                guard let pid = periods[safe: i]?.id else { continue }
                for other in courses(for: weekday, period: pid)
                where !seen.contains(other.courseNo) {
                    add(other, seedIndex: i)
                }
            }
        }
        for c in courses(for: weekday, period: periodId) {
            add(c, seedIndex: periodIndex)
        }
        return resolved
    }

    func pickFromConflict(_ course: SDCourse) {
        guard let target = conflictPickerTarget else { return }
        let weekday = target.weekday
        let periodId = target.periodId
        conflictPickerTarget = nil
        selectCourse(course, weekday: weekday, periodId: periodId)
    }

    func selectCourse(_ course: SDCourse, weekday: Int, periodId: String) {
        selectedWeekday = weekday
        selectedPeriodId = periodId
        selectedCourseBlockTimeRange = nil
        selectedCourse = course
    }

    /// Carousel "Current class" card tap. Carries the block's exact
    /// start/end so the detail sheet shows the tapped block's time
    /// (e.g. periods 3-4 → "10:20 - 12:10") instead of falling back
    /// to `course.timeRange(for:)`, which lumps split same-day blocks
    /// into one whole-day span.
    func selectOngoing(_ info: OngoingCourseInfo) {
        selectedWeekday = info.weekday
        selectedPeriodId = info.firstPeriodId
        selectedCourseBlockTimeRange = info.formattedTimeRange
        selectedCourse = info.course
    }

    /// Returns `true` iff `course` was newly appended to `courses`. The
    /// AddCourseSheet uses this signal to gate its session checkmark so
    /// a rejected add (duplicate, triple-period conflict) can't trick
    /// the next tap into routing through `removeUserAddedCourse`.
    @discardableResult
    func addCourse(_ course: SDCourse) -> Bool {
        // Self-heal the inconsistent state where a course is BOTH tombstoned
        // and currently present in `courses` (e.g. a refresh re-fetched it
        // while a stale tombstone lingered). Done before the early-return so
        // future reloads stop filtering it. Reports `false` since nothing
        // was newly appended — the row was already in the timetable.
        if courses.contains(where: { $0.courseNo == course.courseNo }) {
            if deletedCourseNos.remove(course.courseNo) != nil {
                DataCache.shared.saveDeletedCourseNos(Array(deletedCourseNos))
            }
            return false
        }

        // Refuse if any slot it occupies already has 2 courses — three
        // concurrent courses don't have a sensible rendering (Android caps
        // at 2 with a warning; we surface an alert instead). Must come
        // BEFORE we clear the tombstone, otherwise a rejected add leaves
        // the tombstone cleared and the next reload resurrects the course.
        if let err = wouldCauseTripleConflict(course) {
            tripleConflictError = err
            return false
        }

        if deletedCourseNos.remove(course.courseNo) != nil {
            DataCache.shared.saveDeletedCourseNos(Array(deletedCourseNos))
            if let idnumber = course.moodleIdNumber,
               let numericId = DataCache.shared.lookupMoodleCourseId(idnumber: idnumber) {
                onSyncCourseOverride?(String(numericId), nil, nil, nil)
            }
        }

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
        course.customName = courseCustomNames[course.courseNo]?[currentLocale]

        courses.append(course)
        persistUserAddedCourses()
        broadcastLocalChange()
        onCoursesChanged?(courses, currentSemester)
        return true
    }

    private func persistUserAddedCourses() {
        let userAdded = courses.filter { $0.moodleIdNumber == nil }
        DataCache.shared.saveUserAddedCourses(userAdded)
    }

    private func applyCustomizations(_ courses: inout [SDCourse]) {
        courses.removeAll { deletedCourseNos.contains($0.courseNo) }
        let locale = currentLocale
        for course in courses {
            course.customName = courseCustomNames[course.courseNo]?[locale]
        }
    }

    func deleteCourse(_ course: SDCourse) {
        courses.removeAll { $0.courseNo == course.courseNo }
        deletedCourseNos.insert(course.courseNo)
        DataCache.shared.saveDeletedCourseNos(Array(deletedCourseNos))
        persistUserAddedCourses()
        broadcastLocalChange()
        onCoursesChanged?(courses, currentSemester)
    }

    func resetCourses(authService: AuthService) {
        let semester = CourseSelectionService.currentSemesterCode()
        for courseNo in deletedCourseNos {
            let idnumber = "\(semester)\(courseNo)"
            if let numericId = DataCache.shared.lookupMoodleCourseId(idnumber: idnumber) {
                onSyncCourseOverride?(String(numericId), nil, nil, nil)
            }
        }
        deletedCourseNos.removeAll()
        DataCache.shared.saveDeletedCourseNos([])
        DataCache.shared.saveUserAddedCourses([])
        courseCustomNames.removeAll()
        DataCache.shared.saveCourseCustomNames(courseCustomNames)
        reloadFromCache()
        if let resetBackend = onResetBackendCourses {
            Task { await resetBackend() }
        }
        triggerRefresh(authService: authService)
    }

    /// Undo a not-yet-committed user-added course without tombstoning the
    /// `courseNo`. Used by AddCourseSheet's tap-to-toggle path so the user
    /// can add a course, then immediately tap it again to back out, without
    /// poisoning `deletedCourseNos` — which would later hide any real
    /// enrolled course sharing the same `courseNo` from cache/network merges
    /// (see `applyCustomizations`).
    ///
    /// Defensive: only removes courses that came from the user-added cache
    /// (`moodleIdNumber == nil`). A stray call against a real enrolled course
    /// is a no-op, so callers can route through this without risking the
    /// regular drop/hide flow.
    func removeUserAddedCourse(courseNo: String) {
        guard let course = courses.first(where: { $0.courseNo == courseNo }),
              course.moodleIdNumber == nil
        else { return }
        courses.removeAll { $0.courseNo == courseNo }
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
        let locale = currentLocale
        courseCustomNames[course.courseNo, default: [:]][locale] = trimmed
        DataCache.shared.saveCourseCustomNames(courseCustomNames)
        course.customName = trimmed
        rebuildLookup()
        persistUserAddedCourses()
        courseToRename = nil
        broadcastLocalChange()
        syncNameOverride(course: course, customName: trimmed, locale: locale)
    }

    func revertRename(_ course: SDCourse) {
        let locale = currentLocale
        courseCustomNames[course.courseNo]?[locale] = nil
        // Remove the outer entry entirely when no locale overrides remain
        if courseCustomNames[course.courseNo]?.isEmpty == true {
            courseCustomNames.removeValue(forKey: course.courseNo)
        }
        DataCache.shared.saveCourseCustomNames(courseCustomNames)
        course.customName = nil
        rebuildLookup()
        persistUserAddedCourses()
        courseToRename = nil
        broadcastLocalChange()
        syncNameOverride(course: course, customName: "", locale: locale)
    }

    func startRecolor(_ course: SDCourse) {
        courseToRecolor = course
    }

    /// Apply a user-picked color (preset or fully custom) for this course.
    /// Writes through TigerDuckTheme — which also displaces any other course
    /// currently holding the same hex so the "no two courses share a color"
    /// invariant survives the edit — then broadcasts so Home, Class Table,
    /// widgets and the Live Activity all refresh.
    ///
    /// Intentionally does *not* clear `courseToRecolor`: the ColorPicker
    /// emits a continuous stream of `onSelect` ticks while the user drags
    /// the slider, so auto-dismissing here would close the sheet after the
    /// first intermediate value and strand the rest of the gesture.
    /// `CourseColorPickerSheet` calls `dismiss()` itself when a preset tap
    /// (or the Close button) actually finishes the picking session.
    func setColor(hex: UInt32, for course: SDCourse) {
        TigerDuckTheme.setColor(hex: hex, for: course.courseNo)
        broadcastLocalChange()
        syncColorOverride(course: course, hex: hex)
    }

    private func syncColorOverride(course: SDCourse, hex: UInt32) {
        guard let moodleId = course.moodleIdNumber else { return }
        let hexStr = String(format: "#%06X", hex)
        onSyncCourseOverride?(moodleId, hexStr, nil, nil)
    }

    private func syncNameOverride(course: SDCourse, customName: String, locale: String) {
        guard let moodleId = course.moodleIdNumber else { return }
        onSyncCourseOverride?(moodleId, nil, customName, locale)
    }

    var onSyncCourseOverride: ((_ moodleCourseId: String, _ colorHex: String?, _ customName: String?, _ locale: String?) -> Void)?
    var onCoursesChanged: ((_ courses: [SDCourse], _ semester: String) -> Void)?
    var onResetBackendCourses: (() async -> Void)?

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
            // Pre-flight gates BOTH the fetchData round-trip and the
            // semester-rollover fetchCourses below — gating only
            // fetchData leaves the rollover path firing pinned-host
            // calls under captive Wi-Fi, surfacing the exact TLS-pin
            // error the pre-flight is meant to hide.
            guard await NetworkMonitor.shared.isReachable() else {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    NTUSTSessionManager.shared.loadingState = .error(String(localized: "error_network_unavailable"))
                    self.isRefreshing = false
                }
                return
            }
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
        // Pre-flight here too so the `refresh(authService:)` entry
        // point (used outside triggerRefresh) is also gated. The probe
        // is memoised inside NetworkMonitor so paying for it twice on
        // the triggerRefresh path is effectively free.
        guard await NetworkMonitor.shared.isReachable() else {
            await MainActor.run { manager.loadingState = .error(String(localized: "error_network_unavailable")) }
            return
        }
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
