import SwiftUI

struct WidgetContainer<Content: View>: View {
    let feature: AppFeature
    let size: WidgetItem.WidgetSize
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardPadding()
        .glassCard()
    }
}

struct SimpleWidgetContent: View {
    let feature: AppFeature
    let size: WidgetItem.WidgetSize
    var badgeCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            HStack {
                Image(systemName: feature.iconName)
                    .font(.title2)
                    .foregroundStyle(Color.accentPrimary)
                    .frame(width: 28, height: 28)
                Spacer()
                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.badgeRed, in: Capsule())
                }
            }

            Text(feature.displayName)
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
        }
    }
}
