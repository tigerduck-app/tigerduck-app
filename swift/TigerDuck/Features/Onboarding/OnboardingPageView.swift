import SwiftUI

struct OnboardingPageView<Actions: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    var accentColor: Color = .accentPrimary
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        ScrollView {
            VStack(spacing: TigerDuckTheme.Spacing.lg) {
                Image(systemName: icon)
                    .font(.system(size: 64))
                    .foregroundStyle(accentColor)
                    .symbolEffect(.pulse)

                Text(title)
                    .font(TigerDuckTheme.Typography.title)
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)

                Spacer().frame(height: TigerDuckTheme.Spacing.sm)

                actions()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.top, TigerDuckTheme.Spacing.xxl)
            .padding(.bottom, TigerDuckTheme.Spacing.xxl * 2)
        }
        .scrollIndicators(.never)
    }
}
