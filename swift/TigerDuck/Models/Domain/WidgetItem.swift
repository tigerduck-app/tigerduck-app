import Foundation

struct WidgetItem: Identifiable, Equatable, Codable {
    let id: String
    let feature: AppFeature
    var size: WidgetSize

    enum WidgetSize: String, Codable, CaseIterable {
        case small
        case medium
        case large

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
