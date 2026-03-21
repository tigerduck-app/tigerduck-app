import SwiftUI

struct FeatureCardView: View {
    let feature: AppFeature
    var isPinned: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            HStack {
                Image(systemName: feature.iconName)
                    .font(.title2)
                    .foregroundStyle(Color.accentPrimary)
                Spacer()
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.textSecondary)
                }
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
