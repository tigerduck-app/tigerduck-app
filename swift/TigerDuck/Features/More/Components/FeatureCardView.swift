import SwiftUI

struct FeatureCardView: View {
    let feature: AppFeature

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            HStack {
                Image(systemName: feature.iconName)
                    .font(.title2)
                    .foregroundStyle(Color.accentPrimary)
                    .frame(width: 28, height: 28)
                Spacer()
            }
            Text(feature.displayName)
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
        }
        .cardPadding()
        .glassCard()
    }
}
