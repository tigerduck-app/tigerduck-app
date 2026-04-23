import Foundation

enum AssignmentFilter: String, Sendable {
    case incomplete = "未完成"
    case all = "全部"
    case ignored = "已忽略"

    static func visibleFilters(hasIgnored: Bool) -> [Self] {
        var filters: [Self] = [.incomplete, .all]
        if hasIgnored {
            filters.append(.ignored)
        }
        return filters
    }
}
