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
/// renders `MacMoreView`. Wrapping in an enum keeps the
/// `NavigationSplitView` selection type Hashable while leaving room
/// to grow (a future `.settings` case opens the Settings scene).
enum MacSidebarItem: Hashable {
    case feature(AppFeature)
    case more
}

/// Main sidebar layout: configured features at the top, More at the
/// bottom, the active item's detail view on the right.
///
/// The sidebar is driven by `AppState.configuredTabs` (filtered to
/// drop features Mac doesn't surface — see `AppFeature.isAvailableOnMac`).
/// Adding / removing / reordering pinned features happens in
/// `MacMoreView`; changes propagate live because `configuredTabs` is
/// `@Observable`.
struct MacContentView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: MacSidebarItem = .more

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("TigerDuck")
                .navigationSplitViewColumnWidth(min: 180, ideal: 180, max: 240)
        } detail: {
            detail
                .frame(minWidth: 520, minHeight: 360)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            appState.backgroundSync()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Refresh data (⌘R)")
                    }
                }
        }
        .onAppear(perform: seedSelectionIfNeeded)
        .onChange(of: pinnedFeatures) { _, _ in
            seedSelectionIfNeeded()
        }
    }

    // MARK: - Sidebar + detail

    @ViewBuilder
    private var sidebar: some View {
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
        // First-launch nudge: leave selection on .more (default) when
        // the user hasn't pinned anything yet, otherwise jump to the
        // first pinned item so the app opens on real content.
        if case .more = selection, !pinnedFeatures.isEmpty,
           appState.configuredTabs == AppFeature.defaultTabs {
            // Only auto-jump when the user has the factory defaults —
            // a deliberate "everything unpinned" state stays on More.
            selection = pinnedFeatures.first.map(MacSidebarItem.feature) ?? .more
        }
    }
}

/// Switchboard between the per-feature placeholder views. Each branch
/// will be replaced with a real Mac-native view as features get ported.
struct MacFeatureDetail: View {
    let feature: AppFeature

    var body: some View {
        switch feature {
        case .home:
            MacHomeView()
        case .classTable:
            MacFeaturePlaceholder(
                feature: feature,
                summary: "Your weekly course schedule will appear here once the Class Table view ports to macOS."
            )
        case .calendar:
            MacFeaturePlaceholder(
                feature: feature,
                summary: "School + Moodle events will surface here once the Calendar view ports to macOS."
            )
        case .announcements:
            MacFeaturePlaceholder(
                feature: feature,
                summary: "NTUST bulletins will surface here once the Bulletins view ports to macOS."
            )
        case .gpa:
            MacFeaturePlaceholder(
                feature: feature,
                summary: "Semester scores + GPA chart will surface here once the Score view ports to macOS."
            )
        default:
            MacFeaturePlaceholder(
                feature: feature,
                summary: "This feature isn't ported to macOS yet."
            )
        }
    }
}

/// Single empty-state body used by every sidebar destination until the
/// real feature view ports. Renders the feature icon + name from
/// `AppFeature` so the placeholder still respects whatever the iOS
/// localisation file declares.
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
            Text("Cross-platform service layer is already compiled — only the view is pending.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
