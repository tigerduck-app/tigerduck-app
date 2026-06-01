#if os(macOS)
import SwiftUI

/// Root scene content for the macOS app.
///
/// Routes between the login wall (`MacLoginView`) and the main sidebar
/// layout (`MacContentView`) based on `authService.hasStoredCredentials`,
/// with an in-session bypass via `appState.didSkipMacLogin` (set by the
/// "Skip for now" button on `MacLoginView`). The bypass is intentionally
/// transient: first launch and post-logout always show the login wall
/// again. Silent re-auth failures keep the sidebar visible and surface
/// through `appState.ntustReauthErrorMessage` instead, mirroring the
/// iOS cached-first contract.
struct MacRootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.authService.hasStoredCredentials || appState.didSkipMacLogin {
                MacContentView()
            } else {
                MacLoginView()
            }
        }
        .tint(appState.accentColor)
    }
}

/// Sidebar-side selection model. Pinned features map 1:1 to
/// `AppFeature` cases; `.more` is the synthetic destination that
/// renders `MacMoreView`. Settings is intentionally not in this enum:
/// it opens as a separate window via the system `Settings` scene
/// (driven by `SettingsLink` at the bottom of the sidebar).
enum MacSidebarItem: Hashable {
    case feature(AppFeature)
    case more
}

/// Main sidebar layout: configured features at the top, More plus
/// Settings at the bottom, the active item's detail view on the right.
///
/// The sidebar is driven by `AppState.macConfiguredTabs` (filtered to
/// drop features Mac doesn't surface — see `AppFeature.isAvailableOnMac`).
/// Pinning happens in Settings → Sidebar; changes propagate live
/// because `macConfiguredTabs` is `@Observable`.
struct MacContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: MacSidebarItem = .more

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle(String(localized: "app_name"))
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .frame(minWidth: 640, minHeight: 480)
        }
        .onAppear {
            seedSelectionIfNeeded()
            drainPendingWidgetDestination()
        }
        .onChange(of: pinnedFeatures) { _, _ in
            seedSelectionIfNeeded()
        }
        .onChange(of: appState.pendingWidgetDestination) { _, _ in
            drainPendingWidgetDestination()
        }
    }

    /// Route incoming widget URLs to the matching sidebar selection.
    /// Library is not surfaced on Mac (`macHiddenFeatures`), so library
    /// taps fall back to More — the same place a user goes to enable
    /// Library on iOS — even though the Mac currently offers no toggle.
    private func drainPendingWidgetDestination() {
        guard let destination = appState.pendingWidgetDestination else { return }
        switch destination {
        case .classTable:
            if pinnedFeatures.contains(.classTable) {
                selection = .feature(.classTable)
            } else {
                selection = .more
            }
        case .library:
            selection = .more
        }
        appState.clearPendingWidgetDestination()
    }

    /// Mac sidebar pins live in `macConfiguredTabs`, kept distinct from
    /// `configuredTabs` so Mac pinning doesn't leak past the iOS tab
    /// bar's four-tab cap. First-launch sees `macDefaultTabs`.
    private var isUsingMacFallbackTabs: Bool {
        appState.macConfiguredTabs == AppFeature.macDefaultTabs
    }

    private var sourceConfiguredTabs: [AppFeature] {
        appState.macConfiguredTabs
    }

    // MARK: - Sidebar + detail

    /// The sidebar uses a top-aligned `List` for navigation items plus a
    /// pinned-bottom `VStack` for Settings. Putting Settings in its own
    /// `Section` inside the `List` would push it up against the More
    /// entry; the `Spacer` below the `List` is what holds the Settings
    /// link at the bottom of the window regardless of how many items
    /// are pinned above.
    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    ForEach(pinnedFeatures) { feature in
                        NavigationLink(value: MacSidebarItem.feature(feature)) {
                            Label(feature.displayName, systemImage: feature.iconName)
                        }
                    }
                }

                Section {
                    NavigationLink(value: MacSidebarItem.more) {
                        Label(String(localized: "feature_more"), systemImage: AppFeature.more.iconName)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            SettingsLink {
                Label(String(localized: "feature_settings"), systemImage: "gearshape")
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .feature(let feature):
            MacFeatureDetail(feature: feature)
                .navigationTitle(feature.displayName)
        case .more:
            MacMoreView()
                .navigationTitle(String(localized: "feature_more"))
        }
    }

    // MARK: - Selection bookkeeping

    private var pinnedFeatures: [AppFeature] {
        sourceConfiguredTabs.filter { $0.isAvailableOnMac }
    }

    /// Keep the current selection valid as pinned features mutate.
    /// Two cases:
    ///   1. First launch with no prior selection — land on the first
    ///      pinned feature if any, otherwise on More so the user has a
    ///      surface to pin from.
    ///   2. User unpinned the currently-selected feature — fall back
    ///      to the first remaining pinned feature, else More.
    private func seedSelectionIfNeeded() {
        if case .feature(let current) = selection, !pinnedFeatures.contains(current) {
            selection = pinnedFeatures.first.map(MacSidebarItem.feature) ?? .more
        }
        // First-launch on Mac: land on Home (the first pinned feature)
        // rather than on More so the app opens to real content.
        if case .more = selection, !pinnedFeatures.isEmpty, isUsingMacFallbackTabs {
            selection = pinnedFeatures.first.map(MacSidebarItem.feature) ?? .more
        }
    }
}

/// Switchboard between per-feature detail views.
///
/// The global refresh toolbar lives here (rather than on the outer
/// `NavigationSplitView` detail) so it follows the feature regardless of
/// entry path — sidebar selection or pushed from `MacMoreView`. Putting
/// it on the outer split detail loses the button as soon as More's inner
/// `NavigationStack` pushes a destination, because that inner stack owns
/// the toolbar slot for the pushed view on macOS.
///
/// Scores opts out: it already exposes its own per-feature refresh button
/// (which re-fetches scores — `backgroundSync` doesn't touch the score
/// service), so adding the global one would double up in `.primaryAction`.
struct MacFeatureDetail: View {
    let feature: AppFeature

    var body: some View {
        content
            .toolbar {
                if feature != .gpa {
                    ToolbarItem(placement: .primaryAction) {
                        MacGlobalRefreshButton()
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch feature {
        case .home:
            MacHomeView()
        case .classTable:
            MacClassTableView()
        case .calendar:
            MacCalendarView()
        case .announcements:
            MacBulletinsView()
        case .gpa:
            MacScoreView()
        default:
            MacFeaturePlaceholder(
                feature: feature,
                summary: "This feature isn't ported to macOS yet."
            )
        }
    }
}

/// Triggers `AppState.backgroundSync()` and swaps to a spinner while
/// `sessionManager.loadingState == .loading`. The button stays mounted
/// under the spinner so ⌘R keeps working without separate tracking.
struct MacGlobalRefreshButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            Button {
                appState.backgroundSync()
            } label: {
                Label(String(localized: "mac_action_refresh"), systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help(String(localized: "mac_action_refresh_help"))
            .opacity(isSyncing ? 0 : 1)
            .disabled(isSyncing)

            if isSyncing {
                ProgressView()
                    .controlSize(.small)
                    .help(String(localized: "mac_action_refreshing"))
            }
        }
    }

    private var isSyncing: Bool {
        appState.sessionManager.loadingState == .loading
    }
}

struct MacFeaturePlaceholder: View {
    let feature: AppFeature
    let summary: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: feature.iconName)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(feature.displayName)
                .font(.largeTitle.bold())
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
