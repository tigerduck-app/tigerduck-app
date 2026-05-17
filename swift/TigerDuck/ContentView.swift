import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.hasCompletedOnboarding {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .ntustLoginSheetHost()
    }
}

struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppFeature = .home
    @State private var showTimezoneAlert: Bool = false

    /// Configured tabs filtered to hide library features when disabled
    private var visibleTabs: [AppFeature] {
        appState.configuredTabs.filter { feature in
            if AppFeature.libraryRelatedFeatures.contains(feature) {
                return appState.libraryFeatureEnabled
            }
            return true
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(visibleTabs) { feature in
                Tab(feature.tabBarDisplayName, systemImage: feature.iconName, value: feature) {
                    viewForFeature(feature)
                }
            }

            Tab(AppFeature.more.tabBarDisplayName, systemImage: AppFeature.more.iconName, value: .more) {
                MoreView()
            }
        }
        .alert(
            String(localized: "app_non_taipei_timezone_hint"),
            isPresented: $showTimezoneAlert
        ) {
            Button(String(localized: "action_got_it"), role: .cancel) { }
        }
        .onChange(of: visibleTabs) { _, newTabs in
            if selectedTab != .more, !newTabs.contains(selectedTab), let first = newTabs.first {
                selectedTab = first
            }
        }
        .onAppear {
            drainPendingWidgetDestination()
            // Fresh launch path. `.onChange(of: scenePhase)` won't fire
            // for the initial `.active` value, so the first prompt has
            // to come from here. Subsequent foreground returns go
            // through the scene-phase observer below.
            evaluateTimezoneAlert()
        }
        .onChange(of: appState.pendingWidgetDestination) { _, _ in
            drainPendingWidgetDestination()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Multitask-switch path: every time the app re-enters the
            // foreground, re-evaluate. The observer keeps `isNonTaipei`
            // current against NSSystemTimeZoneDidChange while we were
            // backgrounded, so this read sees the latest decision.
            if newPhase == .active {
                evaluateTimezoneAlert()
            }
        }
        // Mid-foreground transitions matter too: if the user is in the
        // app when the device crosses a timezone boundary (or the debug
        // clock flips to a non-Taipei offset), the observer recomputes
        // immediately and we want to surface the hint right then. Reading
        // the observable here registers the tracking dependency that
        // body evaluation alone otherwise misses.
        .onChange(of: TimezoneObserver.shared.isNonTaipei) { _, isNonTaipei in
            if isNonTaipei {
                showTimezoneAlert = true
            }
        }
    }

    private func evaluateTimezoneAlert() {
        if TimezoneObserver.shared.isNonTaipei {
            showTimezoneAlert = true
        }
    }

    private func drainPendingWidgetDestination() {
        guard let destination = appState.pendingWidgetDestination else { return }
        switch destination {
        case .library:
            // Library has a feature-disabled flag; if disabled, send the user
            // to the More tab and raise an "enable first" alert there, mirroring
            // the Android library-shortcut behavior.
            if appState.libraryFeatureEnabled {
                selectedTab = .library
            } else {
                selectedTab = .more
                appState.pendingLibraryEnablePrompt = true
            }
        case .classTable:
            selectedTab = .classTable
        }
        appState.clearPendingWidgetDestination()
    }

    @ViewBuilder
    private func viewForFeature(_ feature: AppFeature) -> some View {
        switch feature {
        case .home: HomeView()
        case .classTable: ClassTableView()
        case .calendar: CalendarTabView()
        case .announcements: BulletinsView()
        case .gpa: ScoreView()
        case .courseSelection: PlaceholderFeatureView(feature: feature)
        case .graduationRequirements: PlaceholderFeatureView(feature: feature)
        case .library: LibraryView()
        case .discussionRoom: PlaceholderFeatureView(feature: feature)
        case .libraryLecture: PlaceholderFeatureView(feature: feature)
        case .freeLunch: PlaceholderFeatureView(feature: feature)
        case .clubs: PlaceholderFeatureView(feature: feature)
        case .emptyClassroom: PlaceholderFeatureView(feature: feature)
        case .scholarship: PlaceholderFeatureView(feature: feature)
        case .englishVocab: PlaceholderFeatureView(feature: feature)
        default: PlaceholderFeatureView(feature: feature)
        }
    }
}

struct PlaceholderFeatureView: View {
    let feature: AppFeature

    var body: some View {
        NavigationStack {
            VStack(spacing: TigerDuckTheme.Spacing.lg) {
                Image(systemName: feature.iconName)
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentPrimary)
                Text(feature.displayName)
                    .font(TigerDuckTheme.Typography.title)
                    .foregroundStyle(Color.textPrimary)
                Text(String(localized: "library_coming_soon_badge"))
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.backgroundPrimary)
        }
    }
}
