#if os(iOS)
import SwiftUI

extension WhatsNewPage {
    /// 2.3.0: offers the default bottom bar to anyone whose bar differs
    /// from it. Confirming does what the tab editor's Reset defaults +
    /// Apply does — `configuredTabs = AppFeature.defaultTabs` — so the
    /// change syncs and persists the same way.
    static let resetBottomBar = WhatsNewPage.optIn(
        id: "reset-bottom-bar",
        visual: .custom { BottomBarResetDemo() },
        title: WhatsNewText(
            en: "Reset your bottom bar?",
            zhHant: "要恢復預設的底部功能列嗎？"
        ),
        body: WhatsNewText(
            en: "Go back to the default tabs. You can customize them again anytime in Settings.",
            zhHant: "回到預設的項目，之後隨時可以在設定中重新自訂。"
        ),
        confirm: WhatsNewText(en: "Reset Defaults", zhHant: "恢復預設"),
        decline: WhatsNewText(en: "Keep Mine", zhHant: "保留目前設定"),
        isApplicable: { appState in
            offersBottomBarReset(
                configuredTabs: appState.configuredTabs,
                libraryEnabled: appState.libraryFeatureEnabled
            )
        },
        apply: { $0.configuredTabs = AppFeature.defaultTabs }
    )

    /// True when the bar the user actually sees differs from the default
    /// one. Compares what's on screen rather than the stored list, so a
    /// pinned library tab hidden by the library opt-in doesn't make an
    /// already-default bar ask to be reset.
    static func offersBottomBarReset(configuredTabs: [AppFeature], libraryEnabled: Bool) -> Bool {
        AppFeature.visibleTabs(configuredTabs, libraryEnabled: libraryEnabled) != AppFeature.defaultTabs
    }
}

/// A mock of the bottom bar that morphs from the user's tabs into the
/// default ones and back: tabs both bars share slide into place, the
/// rest fade. Reduce Motion shows the two bars stacked instead, and a bar
/// that already is the default just shows still.
private struct BottomBarResetDemo: View {
    @Environment(AppState.self) private var appState
    @Environment(\.whatsNewLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsDefault = false

    private static let yoursCaption = WhatsNewText(en: "Your bottom bar", zhHant: "目前的底部功能列")
    private static let defaultCaption = WhatsNewText(en: "Default", zhHant: "預設")

    private var yours: [AppFeature] {
        AppFeature.visibleTabs(appState.configuredTabs, libraryEnabled: appState.libraryFeatureEnabled) + [.more]
    }

    private var defaults: [AppFeature] {
        AppFeature.defaultTabs + [.more]
    }

    var body: some View {
        Group {
            if yours == defaults {
                // Nothing to morph — a replay for someone already on the
                // default bar, or Back after confirming the reset. Show the
                // default bar still rather than swap it for itself.
                bar(Self.defaultCaption, tabs: defaults)
            } else if reduceMotion {
                VStack(spacing: TigerDuckTheme.Spacing.md) {
                    bar(Self.yoursCaption, tabs: yours)
                    Image(systemName: "arrow.down")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                    bar(Self.defaultCaption, tabs: defaults)
                }
            } else {
                bar(showsDefault ? Self.defaultCaption : Self.yoursCaption, tabs: showsDefault ? defaults : yours)
                    .task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(1.8))
                            withAnimation(.smooth(duration: 0.6)) { showsDefault.toggle() }
                        }
                    }
            }
        }
        .accessibilityHidden(true)
    }

    private func bar(_ caption: WhatsNewText, tabs: [AppFeature]) -> some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            Text(caption.resolved(for: language))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
            HStack(spacing: 0) {
                ForEach(tabs) { feature in
                    VStack(spacing: TigerDuckTheme.Spacing.xs) {
                        Image(systemName: feature.iconName)
                            .font(.system(size: 20))
                            .frame(height: 24)
                        Text(feature.tabBarDisplayName)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(feature == tabs.first ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
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
