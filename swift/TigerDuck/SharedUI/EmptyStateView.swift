import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String? = nil

    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 48

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: heroIconSize))
                .foregroundStyle(Color.textSecondary)
            Text(title)
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
            if let message {
                Text(message)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
