import SwiftUI

@Observable
final class MoreViewModel {
    var isEditing = false
    var pinnedTabs: Set<AppFeature> = []

    var groupedFeatures: [(category: FeatureCategory, features: [AppFeature])] {
        FeatureCategory.allCases.compactMap { category in
            let features = AppFeature.moreFeatures.filter { $0.category == category }
            return features.isEmpty ? nil : (category, features)
        } + [(.system, [.settings])]
    }

    func isPinned(_ feature: AppFeature) -> Bool {
        pinnedTabs.contains(feature)
    }
}
