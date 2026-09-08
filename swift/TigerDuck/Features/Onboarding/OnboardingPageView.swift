import SwiftUI

struct OnboardingPageView<Content: View, Actions: View>: View {
    enum IconAnimation {
        /// Default — the whole symbol pulses once on appear.
        case pulse
        /// Cycles per-layer color: on multi-layer symbols (e.g.
        /// `lock.shield.fill`), the inner layer reads as flashing.
        case layerFlash
    }

    /// What sits at the top of the page.
    ///
    /// `ExpressibleByStringLiteral` so the symbol pages keep reading as
    /// `icon: "lock.shield.fill"` — only the welcome page, which shows the
    /// app's own artwork rather than a stand-in glyph, has to spell out a
    /// case.
    enum Hero: ExpressibleByStringLiteral {
        /// An SF Symbol name, tinted with `accentColor` and animated per
        /// `iconAnimation`.
        case symbol(String)
        /// An asset-catalog image name. Rendered at its own colours —
        /// tinting the logo would flatten it to a silhouette — and so
        /// `accentColor` and `iconAnimation` don't apply.
        case image(String)

        init(stringLiteral value: String) { self = .symbol(value) }
    }

    let icon: Hero
    let title: String
    let subtitle: String
    var accentColor: Color = .onboardingAccent
    var iconAnimation: IconAnimation = .pulse
    /// Fill both margins instead of centring — for the pages whose
    /// subtitle is a paragraph of terms rather than a one-line tagline.
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
        // Pin the page to the device's geometry instead of the keyboard's
        // safe area — when the user focuses a field on the login page, the
        // default SwiftUI behavior is to push the whole VStack (and so the
        // "Sign in" / "Skip for now" actions) up above the keyboard. That
        // makes the buttons jump on focus; we'd rather leave them anchored
        // and let users dismiss the keyboard with the tap-to-dismiss
        // gesture already on this view (the inner ScrollView also has
        // .scrollDismissesKeyboard(.interactively) for finger scroll).
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .contentShape(Rectangle())
        #if canImport(UIKit)
        // `dismissTapGesture` attaches via `.simultaneousGesture` (not
        // `.onTapGesture`): a plain tap recognizer on the page root competes
        // with — and on iOS 18 swallows — taps on the interactive `Link`s /
        // `Button`s inside `content`, which is what left the lower welcome-page
        // links (e.g. GitHub) dead. See View+ScrollSafeGesture.
        .dismissTapGesture { UIApplication.dismissKeyboard() }
        #endif
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .image(let name):
            // Sized larger than the symbol hero: the artwork fills its
            // square edge to edge, where an SF Symbol carries its own
            // optical padding, so matching point sizes would render the
            // logo visibly smaller than the glyph it replaced.
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
