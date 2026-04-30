import Foundation

struct HomeSection: Identifiable, Equatable, Codable {
    let id: String
    var type: HomeSectionType
    var title: String
    var sortOrder: Int
    var isVisible: Bool
    var widgets: [WidgetItem] // only used for .quickWidgets and .custom sections

    enum HomeSectionType: String, Codable, CaseIterable {
        case todayCourses
        case upcomingAssignments
        case quickWidgets
        case custom

        var defaultTitle: String {
            switch self {
            case .todayCourses: String(localized: "home_time_slider_title")
            case .upcomingAssignments: String(localized: "live_activity_status_assignment_short")
            case .quickWidgets: String(localized: "home_section_quick_widgets")
            case .custom: String(localized: "home_section_custom")
            }
        }

        var iconName: String {
            switch self {
            case .todayCourses: "book.fill"
            case .upcomingAssignments: "checklist"
            case .quickWidgets: "square.grid.2x2.fill"
            case .custom: "rectangle.stack.fill"
            }
        }
    }
}
