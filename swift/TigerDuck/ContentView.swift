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
        .modifier(ClassTableImportHost())
        #endif
    }
}

#if os(iOS)
private struct ClassTableImportHost: ViewModifier {
    @Environment(AppState.self) private var appState
    @State private var importModel: ClassTableImportModel?
    /// A link's import, shown over the class table with no camera under it, as on the Mac.
    @State private var linkModel: ClassTableImportModel?

    func body(content: Content) -> some View {
        content
            .environment(\.requestClassTableImport) {
                guard importModel == nil else { return }
                importModel = .live(authService: appState.authService)
            }
            .overlay {
                if linkModel?.isUpdating == true {
                    ZStack {
                        Color.black.opacity(0.4).ignoresSafeArea()
                        ProgressView().controlSize(.large)
                    }
                }
            }
            .fullScreenCover(item: $importModel) { ClassTableImportScannerView(model: $0) }
            .classTableImportPrompts(linkModel, onConfirmScreen: false)
            .sheet(item: Binding(get: { linkModel?.pending }, set: { if $0 == nil { linkModel?.cancel() } })) { pending in
                if let linkModel {
                    ClassTableImportConfirmView(model: linkModel, code: pending.code)
                }
            }
            .onChange(of: linkModel?.isFinished) { _, isFinished in
                if isFinished == true { linkModel = nil }
            }
            .task(id: HeldShareLink.mayOpen(in: appState) ? HeldShareLink.shared.link?.id : nil) {
                while !openHeldLink(), !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
    }

    /// False while the link waits: the import's sheet would close a sheet or alert open in a tab,
    /// and would race a What's New or update sheet about to show.
    private func openHeldLink() -> Bool {
        // A link replaces what an open scanner, or an earlier link's import, shows, inside it.
        let inPlace: ClassTableImportModel? = if let importModel, !importModel.isFinished {
            importModel
        } else if let linkModel, !linkModel.isIdle, !linkModel.isFinished {
            linkModel
        } else {
            nil
        }
        if let inPlace {
            if let text = HeldShareLink.shared.take(in: appState) { inPlace.linkOpened(text) }
            return true
        }
        let othersUp = UIApplication.shared.foregroundRoot?.presentedViewController != nil
            || appState.updateNotifyCoordinator.activeNotifySheet != nil
        if othersUp, HeldShareLink.shared.link != nil, HeldShareLink.mayOpen(in: appState) { return false }
        guard let text = HeldShareLink.shared.take(in: appState) else { return true }
        let model = ClassTableImportModel.live(authService: appState.authService)
        linkModel = model
        model.linkOpened(text)
        return true
    }
}

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

    private var visibleTabs: [AppFeature] { appState.configuredTabs }

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
        .background(
            ClassTableTabBarGestures(
                tabTitle: visibleTabs.contains(.classTable) ? AppFeature.classTable.tabBarDisplayName : nil,
                isShowingClassTable: selectedTab == .classTable,
                store: .shared,
                userName: ClassTableSwitcherEntry.userName(studentId: appState.authService.storedStudentId),
                showClassTable: { selectedTab = .classTable }
            )
        )
        .alert(
            String(localized: "app_non_taipei_timezone_hint"),
            isPresented: $showTimezoneAlert
        ) {
            Button(String(localized: "action_got_it"), role: .cancel) { }
        }
        .onChange(of: visibleTabs, initial: true) { _, newTabs in
            selectedTab = AppFeature.selection(selectedTab, keptOn: newTabs)
        }
        .onAppear {
            drainPendingWidgetDestination()
            // Fresh launch: `.onChange(of: scenePhase)` does not fire for the
            // initial `.active`, so the first prompt comes from here. Later
            // foreground returns go through the scene-phase observer below.
            evaluateTimezoneAlert()
            #if os(iOS)
            appState.updateNotifyCoordinator.evaluateWhatsNewOnLaunch(in: appState)
            appState.updateNotifyCoordinator.checkInBackground()
            #endif
        }
        .onChange(of: appState.pendingWidgetDestination) { _, _ in
            drainPendingWidgetDestination()
        }
        #if os(iOS)
        .onChange(of: appState.pendingDeepLink, initial: true) { _, new in
            routeBulletinDeepLinkIfNeeded(new)
            routeSchoolMailDeepLinkIfNeeded(new)
            routeAssignmentDeepLinkIfNeeded(new)
        }
        #endif
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                evaluateTimezoneAlert()
            }
        }
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
    private func routeBulletinDeepLinkIfNeeded(_ link: AppState.DeepLink?) {
        guard case .bulletin = link else { return }
        open(.announcements)
    }

    private func routeSchoolMailDeepLinkIfNeeded(_ link: AppState.DeepLink?) {
        guard case .schoolMail = link, SchoolMailAvailability.isEnabled else { return }
        open(.schoolMail)
    }

    private func routeAssignmentDeepLinkIfNeeded(_ link: AppState.DeepLink?) {
        guard case .assignment = link else { return }
        open(.home)
    }
    #endif

    private func open(_ feature: AppFeature) {
        let route = AppFeature.tabRoute(to: feature, visibleTabs: visibleTabs)
        selectedTab = route.tab
        if let page = route.moreDeepLink {
            appState.pendingMoreDeepLink = page
        }
    }

    private func drainPendingWidgetDestination() {
        guard let destination = appState.pendingWidgetDestination else { return }
        switch destination {
        case .library:
            open(.library)
        case .classTable:
            ImportedClassTableStore.shared.show(nil)
            open(.classTable)
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
        case .emptyClassroom: EmptyClassroomView()
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
