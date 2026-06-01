import SwiftUI

/// Compact banner shown at the top of protected surfaces when a silent
/// re-authentication attempt failed (e.g. the portal password was
/// changed). Credentials are intentionally kept — the banner lets the
/// user decide between retrying via the login sheet and dismissing to
/// stay on cached data.
struct NTUSTReauthErrorBanner: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "common_auto_sign_in_failed"))
                    .font(.footnote.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(String(localized: "action_sign_in_again"), action: onRetry)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.vertical, TigerDuckTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }
}
