import Foundation

struct WidgetItem: Identifiable, Equatable, Codable {
    let id: String
    let feature: AppFeature
    var size: WidgetSize

    enum WidgetSize: String, Codable, CaseIterable {
        case small  // 1x1
        case medium // 2x1
        case large  // 2x2

        var columns: Int {
            switch self {
            case .small: 1
            case .medium, .large: 2
            }
        }

        var rows: Int {
            switch self {
            case .small, .medium: 1
            case .large: 2
            }
        }
    }
}
