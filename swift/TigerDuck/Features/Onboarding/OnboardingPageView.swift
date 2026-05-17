import SwiftUI

struct OnboardingPageView<Content: View, Actions: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    var accentColor: Color = .accentPrimary
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        GeometryReader { proxy in
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

                    content()

                    Spacer(minLength: TigerDuckTheme.Spacing.lg)

                    actions()
                }
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                .padding(.top, TigerDuckTheme.Spacing.xxl)
                .padding(.bottom, TigerDuckTheme.Spacing.xxl * 2)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                .contentShape(Rectangle())
                .onTapGesture { UIApplication.dismissKeyboard() }
            }
            .scrollIndicators(.never)
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

extension OnboardingPageView where Content == EmptyView {
    init(
        icon: String,
        title: String,
        subtitle: String,
        accentColor: Color = .accentPrimary,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.init(
            icon: icon,
            title: title,
            subtitle: subtitle,
            accentColor: accentColor,
            content: { EmptyView() },
            actions: actions
        )
    }
}
