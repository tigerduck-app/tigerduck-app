import Foundation

enum AssignmentFilter: String, Sendable, CaseIterable {
    case incomplete = "未完成"
    case all = "全部"
    case ignored = "已忽略"

    var displayName: String {
        switch self {
        case .incomplete: return String(localized: "assignment_filter_incomplete")
        case .all:        return String(localized: "assignment_filter_all")
        case .ignored:    return String(localized: "assignment_filter_ignored")
        }
    }

    static func visibleFilters(hasIgnored: Bool) -> [Self] {
        var filters: [Self] = [.incomplete, .all]
        if hasIgnored {
            filters.append(.ignored)
        }
        return filters
    }
}
