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

            GeometryReader { scrollProxy in
                ScrollView {
                    VStack(spacing: TigerDuckTheme.Spacing.lg) {
                        content()
                        Spacer(minLength: TigerDuckTheme.Spacing.lg)
                        actions()
                    }
                    .frame(maxWidth: .infinity, minHeight: scrollProxy.size.height)
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.xxl)
        .padding(.bottom, TigerDuckTheme.Spacing.xxl * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { UIApplication.dismissKeyboard() }
    }

    @ViewBuilder
    private var iconView: some View {
        switch iconAnimation {
        case .pulse:
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundStyle(accentColor)
                .symbolEffect(.pulse)
        case .layerFlash:
            // Compose the shield and lock as separate images so only the
            // lock animates (the built-in lock.shield.fill effect would
            // pulse both layers).
            ZStack {
                Image(systemName: "shield.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(accentColor)
                Image(systemName: "lock.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating.speed(0.35))
                    .offset(y: -4)
            }
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
