import SwiftUI

struct FeatureCategorySection: View {
    let category: FeatureCategory
    let features: [AppFeature]
    var isPinned: (AppFeature) -> Bool = { _ in false }
    var onFeatureTap: ((AppFeature) -> Void)? = nil

    private let columns = [
        GridItem(.flexible(), spacing: TigerDuckTheme.Spacing.md),
        GridItem(.flexible(), spacing: TigerDuckTheme.Spacing.md),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
            SectionHeader(title: category.displayName)

            LazyVGrid(columns: columns, spacing: TigerDuckTheme.Spacing.md) {
                ForEach(features) { feature in
                    Button {
                        onFeatureTap?(feature)
                    } label: {
                        FeatureCardView(feature: feature, isPinned: isPinned(feature))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        }
    }
}
