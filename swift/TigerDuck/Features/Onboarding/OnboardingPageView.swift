import SwiftUI

struct OnboardingPageView<Content: View, Actions: View>: View {
    enum IconAnimation {
        case pulse
        case layerFlash
    }

    enum Hero: ExpressibleByStringLiteral {
        case symbol(String)
        case image(String)

        init(stringLiteral value: String) { self = .symbol(value) }
    }

    let icon: Hero
    let title: String
    let subtitle: String
    var accentColor: Color = .onboardingAccent
    var iconAnimation: IconAnimation = .pulse
    var justifiesSubtitle = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 64

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.lg) {
            iconView

            Text(title)
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if justifiesSubtitle {
                JustifiedText(subtitle, textStyle: .body, color: UIColor(Color.textSecondary))
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            } else {
                Text(subtitle)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            }

            ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    content()
                }
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)

            actions()
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.xxl)
        .padding(.bottom, TigerDuckTheme.Spacing.xxl * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Lay the page out against the device, not the keyboard's safe area: by default, focusing a
        // login field pushes the whole VStack, "Sign in" and "Skip for now" included, above the
        // keyboard, so the buttons jump. Tap-to-dismiss and the ScrollView's scroll dismiss it.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .contentShape(Rectangle())
        #if canImport(UIKit)
        // `simultaneousTapGesture` uses `.simultaneousGesture`, not `.onTapGesture`: a plain tap
        // recognizer on the page root competes with, and on iOS 18 swallows, taps on the `Link`s
        // and `Button`s in `content` (the welcome page's GitHub link). See View+ScrollSafeGesture.
        .simultaneousTapGesture { UIApplication.dismissKeyboard() }
        #endif
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .image(let name):
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: heroIconSize * 1.5, height: heroIconSize * 1.5)
                .accessibilityHidden(true)
        case .symbol(let name):
            symbolIconView(name)
        }
    }

    @ViewBuilder
    private func symbolIconView(_ name: String) -> some View {
        switch iconAnimation {
        case .pulse:
            Image(systemName: name)
                .font(.system(size: heroIconSize))
                .foregroundStyle(accentColor)
                .symbolEffect(.pulse, isActive: !reduceMotion)
        case .layerFlash:
            // Compose the shield and lock as separate images so only the
            // lock animates (the built-in lock.shield.fill effect would
            // pulse both layers).
            ZStack {
                Image(systemName: "shield.fill")
                    .font(.system(size: heroIconSize))
                    .foregroundStyle(accentColor)
                Image(systemName: "lock.fill")
                    .font(.system(size: heroIconSize * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating.speed(0.35), isActive: !reduceMotion)
                    .offset(y: -heroIconSize / 16)
            }
        }
    }
}

extension OnboardingPageView where Content == EmptyView {
    init(
        icon: Hero,
        title: String,
        subtitle: String,
        accentColor: Color = .onboardingAccent,
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
