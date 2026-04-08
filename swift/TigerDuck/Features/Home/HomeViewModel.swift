import SwiftUI

@Observable
final class HomeViewModel {
    var sections: [HomeSection] = []
    var allCourses: [SDCourse] = []
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
        allCourses = courses
        todayCourses = courses.coursesForToday()
        upcomingAssignments = assignments.upcomingSorted()
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

    private func fetchData(authService: AuthService) async {
        let manager = NTUSTSessionManager.shared

        guard NetworkMonitor.shared.isConnected else {
            await MainActor.run { manager.loadingState = .error("無網路連線") }
            return
        }

        await MainActor.run { manager.loadingState = .loading }

        // Authenticate once upfront so parallel tasks reuse the SSO session
        let isAuthenticated = await authService.ensureAuthenticated()

        let allCourses: [SDCourse]
        let allAssignments: [SDAssignment]
        if isAuthenticated {
            async let coursesTask = KMPServiceBridge.fetchCourses(authService: authService)
            async let assignmentsTask = KMPServiceBridge.fetchAssignments(authService: authService)
            (allCourses, allAssignments) = await (coursesTask, assignmentsTask)
        } else {
            allCourses = DataCache.shared.loadCourses()
            allAssignments = DataCache.shared.loadAssignments()
        }

        let todayFiltered = allCourses.coursesForToday()
        let upcoming = allAssignments.upcomingSorted()

        await MainActor.run {
            isUpdatingFromNetwork = true
            TigerDuckTheme.buildCourseColorMap(courseNos: allCourses.map(\.courseNo))
            self.allCourses = allCourses
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
                title: "時光機",
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

            // TODO: Add quickWidgets section once widget features are implemented
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
            UserDefaults.standard.set(data, forKey: AppConstants.UserDefaultsKeys.homeSectionLayout)
        }
    }

    private func loadSectionLayout() -> [HomeSection]? {
        guard let data = UserDefaults.standard.data(forKey: AppConstants.UserDefaultsKeys.homeSectionLayout),
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
