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
            case .todayCourses: "時光機"
            case .upcomingAssignments: "作業"
            case .quickWidgets: "快速功能"
            case .custom: "自訂區塊"
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
