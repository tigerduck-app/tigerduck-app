#if os(iOS)
import SwiftUI

/// Demo for a page that offers to change the tab bar: the user's bar above
/// the one they'd get, both on screen. Leaving tabs are tinted in Before,
/// arriving ones in After. `after` maps the bar the user sees to the offered
/// one; when they match (a replay on the offered bar, or Back after
/// confirming) only one bar shows. Before is read from the live setting each
/// time the page becomes current, then held, so confirming doesn't redraw it
/// as the page slides away. VoiceOver reads one element listing both bars, so
/// the tab a change would remove is heard, not just seen.
struct WhatsNewTabBarChangeDemo: View {
    let after: @MainActor ([AppFeature]) -> [AppFeature]

    @Environment(AppState.self) private var appState
    @Environment(\.whatsNewLanguage) private var language
    @Environment(\.whatsNewPageIsCurrent) private var isCurrent
    @State private var held: [AppFeature]?

    private static let beforeCaption = WhatsNewText(en: "Before", zhHant: "調整前")
    private static let afterCaption = WhatsNewText(en: "After", zhHant: "調整後")
    private static let yoursCaption = WhatsNewText(en: "Your bottom bar", zhHant: "目前的底部功能列")

    init(after: @escaping @MainActor ([AppFeature]) -> [AppFeature]) {
        self.after = after
    }

    var body: some View {
        let before = held ?? visibleTabs
        let offered = after(before)
        Group {
            if before == offered {
                WhatsNewTabBarMock(caption: Self.yoursCaption, tabs: before, highlighted: [])
            } else {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    WhatsNewTabBarMock(
                        caption: Self.beforeCaption,
                        tabs: before,
                        highlighted: Set(before).subtracting(offered)
                    )
                    Image(systemName: "arrow.down")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                    WhatsNewTabBarMock(
                        caption: Self.afterCaption,
                        tabs: offered,
                        highlighted: Set(offered).subtracting(before)
                    )
                }
            }
        }
        .onChange(of: isCurrent, initial: true) { _, isCurrent in
            if isCurrent { held = visibleTabs }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenDescription(before: before, after: offered))
    }

    /// "Before: Home, Class table, Calendar, More. After: Home, Class
    /// table, Mail, More." — or just the one bar when nothing changes.
    private func spokenDescription(before: [AppFeature], after: [AppFeature]) -> String {
        guard before != after else { return spoken(Self.yoursCaption, before) }
        let sentences = [spoken(Self.beforeCaption, before), spoken(Self.afterCaption, after)]
        return language == .zhHant ? sentences.joined(separator: "。") + "。" : sentences.joined(separator: ". ") + "."
    }

    private func spoken(_ caption: WhatsNewText, _ tabs: [AppFeature]) -> String {
        let names = (tabs + [.more]).map(\.tabBarDisplayName)
        return language == .zhHant
            ? caption.resolved(for: language) + "：" + names.joined(separator: "、")
            : caption.resolved(for: language) + ": " + names.joined(separator: ", ")
    }

    private var visibleTabs: [AppFeature] {
        AppFeature.visibleTabs(appState.configuredTabs, libraryEnabled: appState.libraryFeatureEnabled)
    }
}

/// A captioned mock of the tab bar: `tabs` then More, with `highlighted`
/// drawn in the tint and the rest in secondary.
struct WhatsNewTabBarMock: View {
    let caption: WhatsNewText
    let tabs: [AppFeature]
    let highlighted: Set<AppFeature>

    @Environment(\.whatsNewLanguage) private var language

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            Text(caption.resolved(for: language))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                ForEach(tabs + [.more]) { feature in
                    VStack(spacing: TigerDuckTheme.Spacing.xs) {
                        Image(systemName: feature.iconName)
                            .font(.system(size: 20))
                            .frame(height: 24)
                        Text(feature.tabBarDisplayName)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(highlighted.contains(feature) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, TigerDuckTheme.Spacing.md)
            .padding(.horizontal, TigerDuckTheme.Spacing.sm)
            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }
}
#endif
