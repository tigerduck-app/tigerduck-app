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

    var allAssignmentsCache: [SDAssignment] = []

    private var hasLoaded = false
    @ObservationIgnored private var storeObservation: StoreObservation?

    private var isRefreshing = false
    private let courseProvider = CanonicalCourseProvider()

    init() {
        storeObservation = StoreObservation(read: { _ = AppDataRevision.current }) { [weak self] in
            self?.reloadFromCache()
        }
    }

    private func reloadFromCache() {
        let courses = courseProvider.currentCourses()
        let assignments = AssignmentStore.shared.loadAssignments()
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

        reloadFromCache()
    }

    func refresh(authService: AuthService) async {
        await fetchData(authService: authService)
    }

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

        guard await NetworkMonitor.shared.isReachable() else {
            await MainActor.run { manager.loadingState = .error(String(localized: "error_network_unavailable")) }
            return
        }

        await MainActor.run { manager.loadingState = .loading }

        MoodleEnrolledCoursesService.dropSharedAnswer()
        _ = await AppServiceBridge.fetchAssignments(authService: authService, recheckSubmissions: true)
        // Read back from the store, so a mark made while the round ran stays.
        reloadFromCache()
        manager.loadingState = .loaded
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

        ]
    }

    var selectedCourse: SDCourse? = nil
    var selectedCourseSlot: CourseTimeSlot? = nil
    var shownAssignment: MoodleAssignmentPage? = nil
    @ObservationIgnored private var assignmentAfterSheet: MoodleAssignmentPage?

    func archiveAssignment(_ assignment: SDAssignment) {
        guard let idx = allAssignmentsCache.firstIndex(where: { $0.assignmentId == assignment.assignmentId }) else { return }
        withAnimation(prefersReducedMotion ? nil : Self.assignmentMutationAnimation) {
            allAssignmentsCache[idx].isArchived = true
            AssignmentStore.shared.apply(.setArchived(id: assignment.assignmentId, true))
            if allAssignmentsCache[idx].isLocallyCompleted {
                allAssignmentsCache[idx].isLocallyCompleted = false
                AssignmentStore.shared.apply(.setCompleted(id: assignment.assignmentId, false))
            }
            recomputeUpcomingAssignments()
        }
    }

    func unarchiveAssignment(_ assignment: SDAssignment) {
        guard let idx = allAssignmentsCache.firstIndex(where: { $0.assignmentId == assignment.assignmentId }) else { return }
        withAnimation(prefersReducedMotion ? nil : Self.assignmentMutationAnimation) {
            allAssignmentsCache[idx].isArchived = false
            AssignmentStore.shared.apply(.setArchived(id: assignment.assignmentId, false))
            recomputeUpcomingAssignments()
        }
    }

    func markAssignmentAsLocallyCompleted(_ assignment: SDAssignment) {
        guard let idx = allAssignmentsCache.firstIndex(where: { $0.assignmentId == assignment.assignmentId }) else { return }
        withAnimation(prefersReducedMotion ? nil : Self.assignmentMutationAnimation) {
            allAssignmentsCache[idx].isLocallyCompleted = true
            AssignmentStore.shared.apply(.setCompleted(id: assignment.assignmentId, true))
            if allAssignmentsCache[idx].isArchived {
                allAssignmentsCache[idx].isArchived = false
                AssignmentStore.shared.apply(.setArchived(id: assignment.assignmentId, false))
            }
            recomputeUpcomingAssignments()
        }
    }

    func undoLocallyCompleted(_ assignment: SDAssignment) {
        guard let idx = allAssignmentsCache.firstIndex(where: { $0.assignmentId == assignment.assignmentId }) else { return }
        withAnimation(prefersReducedMotion ? nil : Self.assignmentMutationAnimation) {
            allAssignmentsCache[idx].isLocallyCompleted = false
            AssignmentStore.shared.apply(.setCompleted(id: assignment.assignmentId, false))
            recomputeUpcomingAssignments()
        }
    }

    func show(_ page: MoodleAssignmentPage, closingSheet: Bool = true) {
        guard closingSheet, selectedCourse != nil else {
            shownAssignment = page
            return
        }
        assignmentAfterSheet = page
        selectedCourse = nil
    }

    func courseSheetDismissed() {
        guard let page = assignmentAfterSheet else { return }
        assignmentAfterSheet = nil
        shownAssignment = page
    }

    func closeAssignment() {
        assignmentAfterSheet = nil
        shownAssignment = nil
    }

    func assignmentsFor(courseNo: String) -> [SDAssignment] {
        allAssignmentsCache.unfinished(for: courseNo).sorted { $0.dueDate < $1.dueDate }
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

    func addQuickFeature(_ feature: AppFeature) {
        let holdsShortcuts: (HomeSection) -> Bool = { $0.type == .quickWidgets || $0.type == .custom }
        if !sections.contains(where: holdsShortcuts) {
            addSection(type: .quickWidgets, title: HomeSection.HomeSectionType.quickWidgets.defaultTitle)
        }
        guard let target = sections.first(where: holdsShortcuts) else { return }
        addWidget(to: target.id, feature: feature)
    }

    func addWidget(to sectionId: String, feature: AppFeature) {
        guard let idx = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        sections[idx].widgets.append(
            WidgetItem(id: UUID().uuidString, feature: feature, size: .small)
        )
        saveSectionLayout()
    }

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
