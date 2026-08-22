import SwiftUI
import UIKit
import Defaults

@Observable
final class HomeViewModel {
    private static let assignmentMutationAnimation = Animation.snappy(duration: 0.28, extraBounce: 0)

    private var prefersReducedMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    var sections: [HomeSection] = []
    var allCourses: [SDCourse] = []
    var todayCourses: [SDCourse] = []
    var upcomingAssignments: [SDAssignment] = []
    var isEditingHome = false

    var assignmentFilter: AssignmentFilter = AssignmentFilter(
        rawValue: Defaults[.homeAssignmentFilter]
    ) ?? .incomplete {
        didSet {
            guard assignmentFilter != oldValue else { return }
            Defaults[.homeAssignmentFilter] = assignmentFilter.rawValue
            recomputeUpcomingAssignments()
        }
    }

    /// Cached source-of-truth assignment list, already filtered to the current
    /// semester. The visible `upcomingAssignments` is derived from this via
    /// `assignmentFilter` so toggling filters is instant and does not refetch.
    private var allAssignmentsCache: [SDAssignment] = []

    private var hasLoaded = false
    private var isUpdatingFromNetwork = false
    private var dataObserver: Any?

    /// Guards the fire-and-forget pull-to-refresh path against overlapping
    /// fetches. ``triggerRefresh(authService:)`` flips this to `true` while
    /// a fetch is running; additional pulls within that window coalesce
    /// into a no-op instead of stacking concurrent Tasks that would race
    /// on DataCache writes and `dataDidUpdate` notifications.
    private var isRefreshing = false
    /// Single source of truth for the merged course list (portal + user-added,
    /// minus deletions, with custom names overlaid). Sharing this with the
    /// Live Activity stack keeps Home, Class Table, and lock screen aligned.
    private let courseProvider = CanonicalCourseProvider()

    init() {
        dataObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.dataDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Skip if we just posted this notification ourselves (data already up-to-date)
            guard self?.isUpdatingFromNetwork != true else { return }
            self?.reloadFromCache()
        }
    }

    deinit {
        if let observer = dataObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func reloadFromCache() {
        let courses = courseProvider.currentCourses()
        let assignments = DataCache.shared.loadAssignments()
        TigerDuckTheme.ensureAssignments(courseNos: courses.map(\.courseNo))
        allCourses = courses
        todayCourses = courses.coursesForToday()
        allAssignmentsCache = filterToCurrentSemester(assignments, courses: courses)
        recomputeUpcomingAssignments()
    }

    private func filterToCurrentSemester(
        _ assignments: [SDAssignment],
        courses: [SDCourse]
    ) -> [SDAssignment] {
        let currentCourseNos = Set(courses.map(\.courseNo))
        // Empty-course fallback: skip filter so first-launch (no roster yet)
        // does not blank out the assignment list.
        guard !currentCourseNos.isEmpty else { return assignments }
        return assignments.filter { currentCourseNos.contains($0.courseNo) }
    }

    private func recomputeUpcomingAssignments() {
        let availableFilters = AssignmentFilter.visibleFilters(
            hasIgnored: allAssignmentsCache.hasIgnored()
        )
        if !availableFilters.contains(assignmentFilter) {
            assignmentFilter = .all
        }

        switch assignmentFilter {
        case .incomplete:
            upcomingAssignments = allAssignmentsCache.upcomingSorted()
        case .all:
            // Time-agnostic on purpose — the past/future partition runs in
            // `UpcomingAssignmentsView` under its `TimelineView`, so rows
            // re-bucket as the clock advances instead of staying frozen
            // against the `Date()` captured here.
            upcomingAssignments = allAssignmentsCache.allCandidates()
        case .ignored:
            upcomingAssignments = allAssignmentsCache.ignoredSorted()
        }
    }

    var availableAssignmentFilters: [AssignmentFilter] {
        AssignmentFilter.visibleFilters(hasIgnored: allAssignmentsCache.hasIgnored())
    }

    func load(authService: AuthService) {
        guard !hasLoaded else { return }
        hasLoaded = true

        if sections.isEmpty {
            if var saved = loadSectionLayout() {
                let savedIDs = Set(saved.map(\.id))
                let newDefaults = defaultSections().filter { !savedIDs.contains($0.id) }
                if !newDefaults.isEmpty {
                    saved.append(contentsOf: newDefaults)
                }
                sections = saved
            } else {
                sections = defaultSections()
            }
        }

        // Load cached data immediately; backgroundSync() on app launch handles the network refresh
        reloadFromCache()
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
            await MainActor.run { [weak self] in
                self?.isRefreshing = false
            }
        }
    }

    private func fetchData(authService: AuthService) async {
        let manager = NTUSTSessionManager.shared

        // `isReachable()` adds Apple's captive-portal probe on top of
        // the bare interface-up check, so refreshing under a hotel /
        // campus login Wi-Fi surfaces "no internet" instead of the
        // ATS pin failure that would otherwise come from the actual
        // NTUST / Moodle call.
        guard await NetworkMonitor.shared.isReachable() else {
            await MainActor.run { manager.loadingState = .error(String(localized: "error_network_unavailable")) }
            return
        }

        await MainActor.run { manager.loadingState = .loading }

        // Per product spec, Home pull-to-refresh only re-fetches Moodle
        // assignments. The course list is populated by
        // AppState.backgroundSync on cold launch and refreshed on demand
        // from ClassTable pull-to-refresh (which passes
        // `forceRefresh: true`); Home reads it via courseProvider. This
        // avoids paying the 3–5s NTUST SSO round-trip whenever the user
        // just wants to see if any new assignments landed.
        let fetchedAssignments = await AppServiceBridge.fetchAssignments(authService: authService)
        let allCourses = courseProvider.currentCourses()
        let todayFiltered = allCourses.coursesForToday()
        let semesterFiltered = filterToCurrentSemester(fetchedAssignments, courses: allCourses)

        await MainActor.run {
            isUpdatingFromNetwork = true
            TigerDuckTheme.ensureAssignments(courseNos: allCourses.map(\.courseNo))
            self.allCourses = allCourses
            todayCourses = todayFiltered
            allAssignmentsCache = semesterFiltered
            recomputeUpcomingAssignments()
            manager.loadingState = .loaded
            NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
            isUpdatingFromNetwork = false
        }
    }

    private func defaultSections() -> [HomeSection] {
        [
            HomeSection(
                id: "today-courses",
                type: .todayCourses,
                title: String(localized: "home_time_slider_title"),
                sortOrder: 0,
                isVisible: true,
                widgets: []
            ),
            HomeSection(
                id: "upcoming-assignments",
                type: .upcomingAssignments,
                title: String(localized: "live_activity_status_assignment_short"),
                sortOrder: 1,
                isVisible: true,
                widgets: []
            ),

            // TODO: Add quickWidgets section once widget features are implemented
        ]
    }

    var selectedCourse: SDCourse? = nil
    /// Set together with ``selectedCourse`` when the detail sheet is opened
    /// from the TimeSlider so the sheet can render the exact slot the user
    /// tapped (right weekday, right start/end). Nil when the sheet was
    /// opened from somewhere that doesn't have slot context.
    var selectedCourseSlot: CourseTimeSlot? = nil

    func archiveAssignment(_ assignment: SDAssignment) {
        guard let idx = allAssignmentsCache.firstIndex(where: { $0.assignmentId == assignment.assignmentId }) else { return }
        withAnimation(prefersReducedMotion ? nil : Self.assignmentMutationAnimation) {
            allAssignmentsCache[idx].isArchived = true
            DataCache.shared.addArchivedAssignmentId(assignment.assignmentId)
            if allAssignmentsCache[idx].isLocallyCompleted {
                allAssignmentsCache[idx].isLocallyCompleted = false
                DataCache.shared.removeLocallyCompletedAssignmentId(assignment.assignmentId)
            }
            recomputeUpcomingAssignments()
        }
    }

    func unarchiveAssignment(_ assignment: SDAssignment) {
        guard let idx = allAssignmentsCache.firstIndex(where: { $0.assignmentId == assignment.assignmentId }) else { return }
        withAnimation(prefersReducedMotion ? nil : Self.assignmentMutationAnimation) {
            allAssignmentsCache[idx].isArchived = false
            DataCache.shared.removeArchivedAssignmentId(assignment.assignmentId)
            recomputeUpcomingAssignments()
        }
    }

    func markAssignmentAsLocallyCompleted(_ assignment: SDAssignment) {
        guard let idx = allAssignmentsCache.firstIndex(where: { $0.assignmentId == assignment.assignmentId }) else { return }
        withAnimation(prefersReducedMotion ? nil : Self.assignmentMutationAnimation) {
            allAssignmentsCache[idx].isLocallyCompleted = true
            DataCache.shared.addLocallyCompletedAssignmentId(assignment.assignmentId)
            if allAssignmentsCache[idx].isArchived {
                allAssignmentsCache[idx].isArchived = false
                DataCache.shared.removeArchivedAssignmentId(assignment.assignmentId)
            }
            recomputeUpcomingAssignments()
        }
    }

    func undoLocallyCompleted(_ assignment: SDAssignment) {
        guard let idx = allAssignmentsCache.firstIndex(where: { $0.assignmentId == assignment.assignmentId }) else { return }
        withAnimation(prefersReducedMotion ? nil : Self.assignmentMutationAnimation) {
            allAssignmentsCache[idx].isLocallyCompleted = false
            DataCache.shared.removeLocallyCompletedAssignmentId(assignment.assignmentId)
            recomputeUpcomingAssignments()
        }
    }

    func hasUnfinishedAssignment(for courseNo: String) -> Bool {
        upcomingAssignments.hasUnfinished(for: courseNo)
    }

    func assignmentsFor(courseNo: String) -> [SDAssignment] {
        upcomingAssignments.unfinished(for: courseNo)
    }

    func removeSection(_ section: HomeSection) {
        sections.removeAll { $0.id == section.id }
        saveSectionLayout()
    }

    func addSection(type: HomeSection.HomeSectionType, title: String) {
        let section = HomeSection(
            id: UUID().uuidString,
            type: type,
            title: title,
            sortOrder: sections.count,
            isVisible: true,
            widgets: []
        )
        sections.append(section)
        saveSectionLayout()
    }

    func removeWidget(from sectionId: String, widget: WidgetItem) {
        guard let idx = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        sections[idx].widgets.removeAll { $0.id == widget.id }
        saveSectionLayout()
    }

    func addWidget(to sectionId: String, feature: AppFeature) {
        guard let idx = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        sections[idx].widgets.append(
            WidgetItem(id: UUID().uuidString, feature: feature, size: .small)
        )
        saveSectionLayout()
    }

    /// Called by HomeView after drag-reorder completes.
    func saveSectionLayout() {
        reindexSections()
        if let data = try? JSONEncoder().encode(sections) {
            Defaults[.homeSectionLayoutData] = data
        } else {
            Defaults[.homeSectionLayoutData] = nil
        }
    }

    private func loadSectionLayout() -> [HomeSection]? {
        guard let data = Defaults[.homeSectionLayoutData],
              let saved = try? JSONDecoder().decode([HomeSection].self, from: data),
              !saved.isEmpty else { return nil }
        return saved
    }

    private func reindexSections() {
        for i in sections.indices {
            sections[i].sortOrder = i
        }
    }
}
