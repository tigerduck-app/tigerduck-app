import SwiftUI

struct OnboardingPageView<Actions: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    var accentColor: Color = .accentPrimary
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.xxl) {
            Spacer()

            Image(systemName: icon)
                .font(.system(size: 72))
                .foregroundStyle(accentColor)
                .symbolEffect(.pulse)

            VStack(spacing: TigerDuckTheme.Spacing.md) {
                Text(title)
                    .font(TigerDuckTheme.Typography.largeTitle)
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, TigerDuckTheme.Spacing.xxl)
            }

            Spacer()

            actions()
                .padding(.bottom, TigerDuckTheme.Spacing.xxl)
        }
        .padding()
    }
}
