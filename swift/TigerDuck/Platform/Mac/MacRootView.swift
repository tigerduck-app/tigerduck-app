#if os(macOS)
import SwiftUI

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
        .tlsPinPrompt()
        .tint(AccentPreview.shared.tint(saved: appState.accentColor))
    }
}

enum MacSidebarItem: Hashable {
    case feature(AppFeature)
    case more
}

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

    private func drainPendingWidgetDestination() {
        guard let destination = appState.pendingWidgetDestination else { return }
        switch destination {
        case .classTable:
            ImportedClassTableStore.shared.show(nil)
            let route = AppFeature.tabRoute(to: .classTable, visibleTabs: pinnedFeatures)
            selection = route.moreDeepLink == nil ? .feature(.classTable) : .more
            appState.pendingMoreDeepLink = route.moreDeepLink
        case .library:
            selection = .more
        }
        appState.clearPendingWidgetDestination()
    }

    private var isUsingMacFallbackTabs: Bool {
        appState.macConfiguredTabs == AppFeature.macDefaultTabs
    }

    private var sourceConfiguredTabs: [AppFeature] {
        appState.macConfiguredTabs
    }

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

    private var pinnedFeatures: [AppFeature] {
        sourceConfiguredTabs.filter { $0.isAvailableOnMac }
    }

    private func seedSelectionIfNeeded() {
        if case .feature(let current) = selection, !pinnedFeatures.contains(current) {
            selection = pinnedFeatures.first.map(MacSidebarItem.feature) ?? .more
        }
        if case .more = selection, !pinnedFeatures.isEmpty, isUsingMacFallbackTabs {
            selection = pinnedFeatures.first.map(MacSidebarItem.feature) ?? .more
        }
    }
}

/// it or `MacMoreView` pushes it. On the outer `NavigationSplitView` detail, the button
/// would vanish on a push: on macOS More's inner `NavigationStack` owns the pushed view's toolbar.
struct MacFeatureDetail: View {
    let feature: AppFeature

    @State private var refreshShortcutClaimed = false

    var body: some View {
        content
            .onPreferenceChange(MacRefreshShortcutClaimKey.self) { refreshShortcutClaimed = $0 }
            .toolbar {
                if feature != .gpa && feature != .announcements {
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 8) {
                            SyncStatusDot(servers: serversForFeature, lastSynced: .schoolData)
                            MacGlobalRefreshButton(takesShortcut: !refreshShortcutClaimed)
                        }
                    }
                }
            }
    }

    private var serversForFeature: [ServerKind] {
        switch feature {
        case .home: [.moodle, .backend]
        case .classTable: ServerKind.classTableSources
        case .calendar: [.moodle, .courseSelection, .backend]
        default: ServerKind.allCases
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

struct MacRefreshShortcutClaimKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct MacGlobalRefreshButton: View {
    var takesShortcut = true

    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            Button {
                appState.backgroundSync(recheckSubmissions: true)
            } label: {
                Label(String(localized: "desktop_action_refresh"), systemImage: "arrow.clockwise")
            }
            .keyboardShortcut(takesShortcut ? KeyboardShortcut("r", modifiers: .command) : nil)
            .help(String(localized: "desktop_action_refresh_help"))
            .opacity(isSyncing ? 0 : 1)
            .disabled(isSyncing)

            if isSyncing {
                ProgressView()
                    .controlSize(.small)
                    .help(String(localized: "desktop_action_refreshing"))
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
