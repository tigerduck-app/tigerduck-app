import Foundation
import SwiftData

@Model
final class SDHomeSectionConfig {
    @Attribute(.unique) var sectionId: String
    var typeRaw: String
    var title: String
    var sortOrder: Int
    var isVisible: Bool
    var widgetFeaturesJSON: String

    init(
        sectionId: String = UUID().uuidString,
        type: HomeSection.HomeSectionType,
        title: String,
        sortOrder: Int,
        isVisible: Bool = true,
        widgetFeatures: [String] = []
    ) {
        self.sectionId = sectionId
        self.typeRaw = type.rawValue
        self.title = title
        self.sortOrder = sortOrder
        self.isVisible = isVisible
        self.widgetFeaturesJSON = (try? JSONEncoder().encode(widgetFeatures))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    var type: HomeSection.HomeSectionType {
        HomeSection.HomeSectionType(rawValue: typeRaw) ?? .custom
    }

    var widgetFeatures: [String] {
        get {
            guard let data = widgetFeaturesJSON.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return arr
        }
        set {
            widgetFeaturesJSON = (try? JSONEncoder().encode(newValue))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
    }
}
