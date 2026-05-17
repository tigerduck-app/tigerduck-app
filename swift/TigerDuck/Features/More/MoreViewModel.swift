import SwiftUI

@Observable
final class MoreViewModel {
    var isEditing = false

    let groupedFeatures: [(category: FeatureCategory, features: [AppFeature])] = {
        FeatureCategory.allCases.compactMap { category in
            let features = AppFeature.moreFeatures.filter { $0.category == category }
            return features.isEmpty ? nil : (category, features)
        }
    }()
}
