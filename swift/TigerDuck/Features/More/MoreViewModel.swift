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

    /// `pinnedTabs` previously held a never-written `Set<AppFeature>`,
    /// so the pin badge was always false. Read from `AppState`'s
    /// `configuredTabs` instead — the actual source of truth for which
    /// features are pinned to the bottom tab bar.
    func isPinned(_ feature: AppFeature, in appState: AppState) -> Bool {
        appState.configuredTabs.contains(feature)
    }
}
