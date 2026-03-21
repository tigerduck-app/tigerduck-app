import Foundation
import SwiftData

@Model
final class SDWidgetConfig {
    @Attribute(.unique) var featureRawValue: String
    var sizeRawValue: String
    var sortOrder: Int
    var isVisible: Bool
    /// "home" or "more"
    var section: String

    init(
        feature: AppFeature,
        size: WidgetItem.WidgetSize = .small,
        sortOrder: Int,
        isVisible: Bool = true,
        section: String = "more"
    ) {
        self.featureRawValue = feature.rawValue
        self.sizeRawValue = size.rawValue
        self.sortOrder = sortOrder
        self.isVisible = isVisible
        self.section = section
    }

    var feature: AppFeature? {
        AppFeature(rawValue: featureRawValue)
    }

    var size: WidgetItem.WidgetSize {
        get { WidgetItem.WidgetSize(rawValue: sizeRawValue) ?? .small }
        set { sizeRawValue = newValue.rawValue }
    }
}
