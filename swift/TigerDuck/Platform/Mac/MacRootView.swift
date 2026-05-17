#if os(macOS)
import SwiftUI

/// Root scene content for the macOS app.
///
/// Routes between the login wall (`MacLoginView`) and the main sidebar
/// layout (`MacContentView`) based on `authService.hasStoredCredentials`.
/// Once credentials are in the Keychain the user sees the sidebar; full
/// logout drops them back to login. Silent re-auth failures keep the
/// sidebar visible and surface through `appState.ntustReauthErrorMessage`
/// instead, mirroring the iOS cached-first contract.
struct MacRootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.authService.hasStoredCredentials {
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
/// The sidebar is driven by `AppState.configuredTabs` (filtered to
/// drop features Mac doesn't surface — see `AppFeature.isAvailableOnMac`).
/// Pinning happens in Settings → Sidebar; changes propagate live
/// because `configuredTabs` is `@Observable`.
struct MacContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: MacSidebarItem = .more

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("TigerDuck")
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .frame(minWidth: 640, minHeight: 480)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        refreshToolbarControl
                    }
                }
        }
        .onAppear {
            seedMacDefaultsIfNeeded()
            seedSelectionIfNeeded()
        }
        .onChange(of: pinnedFeatures) { _, _ in
            seedSelectionIfNeeded()
        }
    }

    /// First-launch Mac users get a wider default pin set than iOS
    /// because the sidebar isn't capped at 4. Only kick in when
    /// `configuredTabs` is still exactly the iOS default — once the
    /// user has touched their pins, respect their choice.
    private func seedMacDefaultsIfNeeded() {
        if appState.configuredTabs == AppFeature.defaultTabs {
            appState.configuredTabs = AppFeature.macDefaultTabs
        }
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
                        Label("More", systemImage: AppFeature.more.iconName)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
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

    /// Toolbar refresh affordance. Swaps to a spinner while
    /// `sessionManager.loadingState == .loading` so the user sees the
    /// active sync (⌘R still triggers via the hidden button). Keeping
    /// the button mounted under the spinner lets the keyboard shortcut
    /// stay registered without us tracking it separately.
    @ViewBuilder
    private var refreshToolbarControl: some View {
        ZStack {
            Button {
                appState.backgroundSync()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh data (⌘R)")
            .opacity(isSyncing ? 0 : 1)
            .disabled(isSyncing)

            if isSyncing {
                ProgressView()
                    .controlSize(.small)
                    .help("Refreshing…")
            }
        }
    }

    private var isSyncing: Bool {
        appState.sessionManager.loadingState == .loading
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .feature(let feature):
            MacFeatureDetail(feature: feature)
                .navigationTitle(feature.displayName)
        case .more:
            MacMoreView()
                .navigationTitle("More")
        }
    }

    // MARK: - Selection bookkeeping

    private var pinnedFeatures: [AppFeature] {
        appState.configuredTabs.filter { $0.isAvailableOnMac }
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
        if case .more = selection, !pinnedFeatures.isEmpty,
           appState.configuredTabs == AppFeature.macDefaultTabs {
            selection = pinnedFeatures.first.map(MacSidebarItem.feature) ?? .more
        }
    }
}

/// Switchboard between per-feature detail views.
struct MacFeatureDetail: View {
    let feature: AppFeature

    var body: some View {
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
