import SwiftUI

/// Presents a login-required prompt on surfaces that require a 校務系統
/// session. Supports two layouts:
///
/// - ``Layout/page``: full-page placeholder used when an entire screen is
///   gated (e.g. the Class Table tab).
/// - ``Layout/section``: compact card used inline when only a section of a
///   screen is gated (e.g. Home's time slider and upcoming assignments).
struct LoginRequiredView: View {
    enum Layout {
        case page
        case section
    }

    let layout: Layout
    let title: String
    let message: String
    var primaryTitle: String = "登入校務系統"
    var secondaryTitle: String? = nil
    let onPrimary: () -> Void
    var onSecondary: (() -> Void)? = nil

    var body: some View {
        switch layout {
        case .page:
            pageBody
        case .section:
            sectionBody
        }
    }

    private var pageBody: some View {
        VStack(spacing: TigerDuckTheme.Spacing.lg) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentPrimary)
            Text(title)
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Text(message)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)

            VStack(spacing: TigerDuckTheme.Spacing.sm) {
                Button(action: onPrimary) {
                    Text(primaryTitle)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, TigerDuckTheme.Spacing.md)
                }
                .buttonStyle(.borderedProminent)

                if let secondaryTitle, let onSecondary {
                    Button(action: onSecondary) {
                        Text(secondaryTitle)
                            .font(.body)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, TigerDuckTheme.Spacing.sm)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.xl)
            .padding(.top, TigerDuckTheme.Spacing.md)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, TigerDuckTheme.Spacing.xxl)
    }

    private var sectionBody: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            HStack(alignment: .top, spacing: TigerDuckTheme.Spacing.md) {
                Image(systemName: "lock.shield")
                    .font(.title3)
                    .foregroundStyle(Color.accentPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TigerDuckTheme.Typography.headline)
                        .foregroundStyle(Color.textPrimary)
                    Text(message)
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                Button(action: onPrimary) {
                    Text(primaryTitle)
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, TigerDuckTheme.Spacing.md)
                        .padding(.vertical, TigerDuckTheme.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)

                if let secondaryTitle, let onSecondary {
                    Button(action: onSecondary) {
                        Text(secondaryTitle)
                            .font(.callout)
                            .padding(.horizontal, TigerDuckTheme.Spacing.md)
                            .padding(.vertical, TigerDuckTheme.Spacing.sm)
                    }
                    .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(TigerDuckTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }
}
