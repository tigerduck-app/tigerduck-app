import Foundation
import SwiftData

@Model
final class SDTabConfig {
    /// Position 0-3 (position 4 is always "more")
    @Attribute(.unique) var position: Int
    var featureRawValue: String

    init(position: Int, feature: AppFeature) {
        self.position = position
        self.featureRawValue = feature.rawValue
    }

    var feature: AppFeature? {
        AppFeature(rawValue: featureRawValue)
    }
}
