import SwiftUI

struct FeatureCategorySection: View {
    let category: FeatureCategory
    let features: [AppFeature]
    var isPinned: (AppFeature) -> Bool = { _ in false }

    private let columns = [
        GridItem(.flexible(), spacing: TigerDuckTheme.Spacing.md),
        GridItem(.flexible(), spacing: TigerDuckTheme.Spacing.md),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            SectionHeader(title: category.displayName)

            LazyVGrid(columns: columns, spacing: TigerDuckTheme.Spacing.md) {
                ForEach(features) { feature in
                    FeatureCardView(feature: feature, isPinned: isPinned(feature))
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        }
    }
}
