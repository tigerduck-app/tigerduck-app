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
            ) { popup in
                // Mark here, not at routing time: a presented popup joins the FIFO
                // dedupe, while one a competing modal suppressed stays unseen and
                // can present again on the next tap.
                Button(String(localized: "action_got_it"), role: .cancel) {
                    appState.markServerPopupShown(popup.id)
                }
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
        AppFeature.visibleTabs(appState.configuredTabs, libraryEnabled: appState.libraryFeatureEnabled)
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
            // Fresh launch: `.onChange(of: scenePhase)` does not fire for the
            // initial `.active`, so the first prompt comes from here. Later
            // foreground returns go through the scene-phase observer below.
            evaluateTimezoneAlert()
            #if os(iOS)
            // Runs only after onboarding (MainTabView is gated on it), and the
            // fresh-install branch of AppState.init stamps lastShownWhatsNewVersion,
            // so a new user's first home screen gets no What's New on top.
            appState.updateNotifyCoordinator.evaluateWhatsNewOnLaunch(in: appState)
            // The coordinator skips the check until `hasCompletedOnboarding`: under
            // OnboardingView a `pendingUpdate` has no sheet host. So a new user's first
            // iTunes Lookup runs here; the throttle absorbs later repeats.
            appState.updateNotifyCoordinator.checkInBackground()
            #endif
        }
        .onChange(of: appState.pendingWidgetDestination) { _, _ in
            drainPendingWidgetDestination()
        }
        #if os(iOS)
        // A custom_push_bulletin tap arrives as `pendingDeepLink` before BulletinsView
        // mounts. Switch to the announcements tab (via More if unpinned) so the view
        // drains the link and pushes the detail screen.
        .onChange(of: appState.pendingDeepLink, initial: true) { _, new in
            routeBulletinDeepLinkIfNeeded(new)
            routeSchoolMailDeepLinkIfNeeded(new)
        }
        #endif
        .onChange(of: scenePhase) { _, newPhase in
            // Re-evaluate on every return to the foreground. The observer tracked
            // NSSystemTimeZoneDidChange while backgrounded, so `isNonTaipei` is
            // current here.
            if newPhase == .active {
                evaluateTimezoneAlert()
            }
        }
        // Also mid-foreground: crossing a timezone, or the debug clock moving to a
        // non-Taipei offset, should show the hint at once. Reading the observable
        // here registers the dependency that body evaluation alone misses.
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

    /// Switches to the School Mail tab (or routes via More if it isn't
    /// pinned) when a mail notification is tapped. Guarded on
    /// `SchoolMailAvailability.isEnabled` so a stale/synced deep link
    /// never opens the feature on a build where it's hidden.
    private func routeSchoolMailDeepLinkIfNeeded(_ link: AppState.DeepLink?) {
        guard case .schoolMail = link, SchoolMailAvailability.isEnabled else { return }
        if visibleTabs.contains(.schoolMail) {
            selectedTab = .schoolMail
        } else {
            selectedTab = .more
            appState.pendingMoreDeepLink = .schoolMail
        }
    }
    #endif

    private func drainPendingWidgetDestination() {
        guard let destination = appState.pendingWidgetDestination else { return }
        switch destination {
        case .library:
            // Disabled: open More with an "enable first" alert, as Android does. Enabled
            // but unpinned: a selection no `Tab` matches breaks the `TabView`, so MoreView
            // pushes Library; switching to More alone would never show the QR.
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
        #if os(iOS)
        case .schoolMail: SchoolMailView()
        #endif
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
                    .foregroundStyle(.tint)
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
