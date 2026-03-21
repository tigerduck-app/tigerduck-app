import SwiftUI

struct MoreView: View {
    @State private var viewModel = MoreViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    HStack {
                        Text("更多")
                            .font(TigerDuckTheme.Typography.title)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.top, TigerDuckTheme.Spacing.md)

                    ForEach(viewModel.groupedFeatures, id: \.category) { group in
                        FeatureCategorySection(
                            category: group.category,
                            features: group.features,
                            isPinned: viewModel.isPinned
                        )
                    }
                }
                .padding(.bottom, TigerDuckTheme.Spacing.xxl)
            }
            .background(Color.backgroundPrimary)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
    }
}

