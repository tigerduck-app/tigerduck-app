import SwiftUI

@Observable
final class HomeViewModel {
    var sections: [HomeSection] = []
    var todayCourses: [SDCourse] = []
    var upcomingAssignments: [SDAssignment] = []
    var isEditingHome = false

    private var hasLoaded = false
    private var isUpdatingFromNetwork = false
    private var dataObserver: Any?

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
        let courses = DataCache.shared.loadCourses()
        let assignments = DataCache.shared.loadAssignments()
        TigerDuckTheme.buildCourseColorMap(courseNos: courses.map(\.courseNo))
        todayCourses = courses.coursesForToday()
        upcomingAssignments = assignments.upcomingSorted()
    }

    func load(authService: AuthService) {
        guard !hasLoaded else { return }
        hasLoaded = true

        if sections.isEmpty {
            sections = defaultSections()
        }

        // Load cached data immediately; backgroundSync() on app launch handles the network refresh
        reloadFromCache()
    }

    func refresh(authService: AuthService) async {
        await fetchData(authService: authService)
    }

    private func fetchData(authService: AuthService) async {
        let manager = NTUSTSessionManager.shared
        await MainActor.run { manager.loadingState = .loading }

        async let coursesTask = KMPServiceBridge.fetchCourses(authService: authService)
        async let assignmentsTask = KMPServiceBridge.fetchAssignments(authService: authService)

        let allCourses = await coursesTask
        let allAssignments = await assignmentsTask

        let todayFiltered = allCourses.coursesForToday()
        let upcoming = allAssignments.upcomingSorted()

        await MainActor.run {
            isUpdatingFromNetwork = true
            TigerDuckTheme.buildCourseColorMap(courseNos: allCourses.map(\.courseNo))
            todayCourses = todayFiltered
            upcomingAssignments = upcoming
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
                title: "今日課程",
                sortOrder: 0,
                isVisible: true,
                widgets: []
            ),
            HomeSection(
                id: "upcoming-assignments",
                type: .upcomingAssignments,
                title: "待辦作業",
                sortOrder: 1,
                isVisible: true,
                widgets: []
            ),
            HomeSection(
                id: "quick-widgets",
                type: .quickWidgets,
                title: "快速功能",
                sortOrder: 2,
                isVisible: true,
                widgets: [
                    WidgetItem(id: "w1", feature: .freeLunch, size: .small),
                    WidgetItem(id: "w2", feature: .emptyClassroom, size: .small),
                    WidgetItem(id: "w3", feature: .scholarship, size: .small),
                    WidgetItem(id: "w4", feature: .gpa, size: .small),
                ]
            ),
        ]
    }

    var selectedCourse: SDCourse? = nil

    func hasUnfinishedAssignment(for courseNo: String) -> Bool {
        upcomingAssignments.hasUnfinished(for: courseNo)
    }

    func assignmentsFor(courseNo: String) -> [SDAssignment] {
        upcomingAssignments.unfinished(for: courseNo)
    }

    func removeSection(_ section: HomeSection) {
        sections.removeAll { $0.id == section.id }
        reindexSections()
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
    }

    func removeWidget(from sectionId: String, widget: WidgetItem) {
        guard let idx = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        sections[idx].widgets.removeAll { $0.id == widget.id }
    }

    func addWidget(to sectionId: String, feature: AppFeature) {
        guard let idx = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        sections[idx].widgets.append(
            WidgetItem(id: UUID().uuidString, feature: feature, size: .small)
        )
    }

    private func reindexSections() {
        for i in sections.indices {
            sections[i].sortOrder = i
        }
    }
}
