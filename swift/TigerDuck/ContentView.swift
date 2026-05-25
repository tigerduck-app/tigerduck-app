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
        #if os(iOS)
        .serverPushPopupHost()
        #endif
    }
}

#if os(iOS)
/// Hosts the modal alert that surfaces an operator-issued
/// `custom_push_popup` tap. Pulled into its own modifier so the binding
/// dance (Optional<ServerPopupPayload> → Bool) stays local and the
/// root view's `body` doesn't grow another inline `.alert`.
private struct ServerPushPopupHost: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        @Bindable var bindable = appState
        content
            .alert(
                bindable.pendingServerPopup?.title ?? "",
                isPresented: Binding(
                    get: { bindable.pendingServerPopup != nil },
                    set: { newValue in
                        if !newValue { bindable.pendingServerPopup = nil }
                    }
                ),
                presenting: bindable.pendingServerPopup
            ) { _ in
                // System-localized "OK" / "確定" comes from the cancel role.
                Button(String(localized: "action_got_it"), role: .cancel) {}
            } message: { popup in
                Text(popup.body)
            }
    }
}

private extension View {
    func serverPushPopupHost() -> some View {
        modifier(ServerPushPopupHost())
    }
}
#endif

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
            #if os(iOS)
            // Only check the What's New gate AFTER onboarding completes
            // (MainTabView is itself gated on that in ContentView), so
            // a brand-new user finishing onboarding doesn't get
            // What's New layered on top of their first home screen —
            // the seed in AppState.init's fresh-install branch already
            // stamped lastShownWhatsNewVersion in that case.
            appState.updateNotifyCoordinator.evaluateWhatsNewOnLaunch()
            // Background update check is gated on `hasCompletedOnboarding`
            // inside the coordinator, so a brand-new user landing on
            // MainTabView for the first time gets the first iTunes
            // Lookup HERE (the `TigerDuckApp.onAppear` kick-off no-oped
            // while OnboardingView was on screen, which would otherwise
            // strand `pendingUpdate` behind an un-mounted sheet host).
            // Throttle absorbs the dupe on subsequent appearances.
            appState.updateNotifyCoordinator.checkInBackground()
            #endif
        }
        .onChange(of: appState.pendingWidgetDestination) { _, _ in
            drainPendingWidgetDestination()
        }
        #if os(iOS)
        // Tap on a custom_push_bulletin notification arrives as a
        // pendingDeepLink before BulletinsView is mounted. Switch to the
        // announcements tab (or route via More if it isn't pinned) so the
        // view drains the deep link and pushes the detail screen.
        .onChange(of: appState.pendingDeepLink, initial: true) { _, new in
            routeBulletinDeepLinkIfNeeded(new)
        }
        #endif
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
        #if os(iOS)
        .flipToLibraryAttached()
        .firstTriggerPromptHost()
        .updateNotifySheetHost()
        #endif
    }

    private func evaluateTimezoneAlert() {
        if TimezoneObserver.shared.isNonTaipei {
            showTimezoneAlert = true
        }
    }

    #if os(iOS)
    /// Switches to the announcements tab when a bulletin deep link is set
    /// so `BulletinsView` mounts and its own onChange handler can navigate
    /// to the detail view. The deep link itself is left in place — the
    /// downstream view clears it after acting.
    private func routeBulletinDeepLinkIfNeeded(_ link: AppState.DeepLink?) {
        guard case .bulletin = link else { return }
        if visibleTabs.contains(.announcements) {
            selectedTab = .announcements
        } else {
            selectedTab = .more
            appState.pendingMoreDeepLink = .announcements
        }
    }
    #endif

    private func drainPendingWidgetDestination() {
        guard let destination = appState.pendingWidgetDestination else { return }
        switch destination {
        case .library:
            // Library has a feature-disabled flag; if disabled, send the user
            // to the More tab and raise an "enable first" alert there, mirroring
            // the Android library-shortcut behavior.
            //
            // Library can also be enabled-but-not-pinned-as-a-tab (fresh
            // defaults pin only Home/Class/Calendar, and the Settings enable
            // path only auto-adds Library when there is room). Selecting a
            // value that no `Tab` matches would leave the `TabView` in a
            // broken state, so route to More and ask MoreView to push the
            // Library destination onto its NavigationStack — that's the
            // only path that actually surfaces the QR. Just switching to
            // More would leave the user on the category list and the
            // flip would silently fail to open Library.
            if appState.libraryFeatureEnabled {
                if visibleTabs.contains(.library) {
                    selectedTab = .library
                } else {
                    selectedTab = .more
                    appState.pendingMoreDeepLink = .library
                }
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
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 48

    var body: some View {
        NavigationStack {
            VStack(spacing: TigerDuckTheme.Spacing.lg) {
                Image(systemName: feature.iconName)
                    .font(.system(size: heroIconSize))
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
