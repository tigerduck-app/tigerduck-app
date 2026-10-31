import Defaults
import Foundation

/// Home's sections and the shortcuts in them, in the order the user arranged, kept in
/// `homeSectionLayoutData`.
@Observable
final class HomeLayout {
    var sections: [HomeSection] = []

    /// Reads the saved layout once, adding any section a newer version brought.
    func loadIfEmpty() {
        guard sections.isEmpty else { return }
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
