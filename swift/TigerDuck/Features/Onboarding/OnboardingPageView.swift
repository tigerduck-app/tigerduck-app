import SwiftUI

struct OnboardingPageView<Content: View, Actions: View>: View {
    enum IconAnimation {
        /// Default — the whole symbol pulses once on appear.
        case pulse
        /// Cycles per-layer color: on multi-layer symbols (e.g.
        /// `lock.shield.fill`), the inner layer reads as flashing.
        case layerFlash
    }

    let icon: String
    let title: String
    let subtitle: String
    var accentColor: Color = .accentPrimary
    var iconAnimation: IconAnimation = .pulse
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    iconView

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

    @ViewBuilder
    private var iconView: some View {
        let image = Image(systemName: icon)
            .font(.system(size: 64))
            .foregroundStyle(accentColor)

        switch iconAnimation {
        case .pulse:
            image.symbolEffect(.pulse)
        case .layerFlash:
            image
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
        }
    }
}

extension OnboardingPageView where Content == EmptyView {
    init(
        icon: String,
        title: String,
        subtitle: String,
        accentColor: Color = .accentPrimary,
        iconAnimation: IconAnimation = .pulse,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.init(
            icon: icon,
            title: title,
            subtitle: subtitle,
            accentColor: accentColor,
            iconAnimation: iconAnimation,
            content: { EmptyView() },
            actions: actions
        )
    }
}
