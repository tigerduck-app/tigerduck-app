import SwiftUI

@Observable
final class HomeViewModel {
    var sections: [HomeSection] = []
    var todayCourses: [SDCourse] = []
    var upcomingAssignments: [SDAssignment] = []
    var isEditingHome = false

    func load() {
        let today = Date().weekdayIndex + 1
        todayCourses = MockData.courses.filter { $0.schedule[today] != nil }
        upcomingAssignments = MockData.assignments
            .filter { !$0.isCompleted }
            .sorted { $0.dueDate < $1.dueDate }

        if sections.isEmpty {
            sections = defaultSections()
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
                    WidgetItem(id: "w1", feature: .announcements, size: .small),
                    WidgetItem(id: "w2", feature: .freeLunch, size: .small),
                    WidgetItem(id: "w3", feature: .clubs, size: .small),
                    WidgetItem(id: "w4", feature: .emptyClassroom, size: .small),
                ]
            ),
        ]
    }

    func hasUnfinishedAssignment(for courseNo: String) -> Bool {
        upcomingAssignments.contains { $0.courseNo == courseNo && !$0.isCompleted }
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
