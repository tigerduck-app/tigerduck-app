import SwiftUI

/// A list's first load that failed, with a way to try again.
struct LoadFailureView: View {
    let title: String
    let message: String
    let onRetry: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 36

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: heroIconSize))
                .foregroundStyle(Color.orange)
            Text(title)
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
            Text(message)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            Button(String(localized: "action_retry"), action: onRetry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
