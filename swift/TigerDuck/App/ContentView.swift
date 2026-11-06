import SwiftUI

struct ContentView: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        Group {
            if app.hasCompletedOnboarding {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .ntustLoginSheetHost()
        #if os(iOS)
        .serverPushPopupHost()
        .modifier(ClassTableImportHost())
        .heldMailHost()
        #endif
    }
}

#if os(iOS)
private struct ClassTableImportHost: ViewModifier {
    @Environment(AppEnvironment.self) private var app
    @State private var importModel: ClassTableImportModel?
    /// A link's import, apart from the scanner's, so opening a link never starts the camera or asks
    /// for its permission.
    @State private var linkModel: ClassTableImportModel?
    @State private var shareModel: ClassTableShareModel?
    /// The share sheet the scanner hands over, shown only once the scanner is gone, as the root
    /// presents both.
    @State private var shareAfterScanner: ClassTableShareModel?
    /// The sheets shown here sit outside MainTabView's window reader.
    @State private var hostWindow = HostWindow()
    @State private var keyWindowChanges = 0

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $importModel, onDismiss: {
                shareModel = shareAfterScanner
                shareAfterScanner = nil
            }) { ClassTableImportScannerView(model: $0, onShare: { shareAfterScanner = $0 }) }
            .classTableShareSheet(model: $shareModel, signIn: app.authService.session.currentSignIn)
            .classTableImportPrompts(linkModel, onConfirmScreen: false)
            .sheet(item: Binding(get: { linkModel?.pending }, set: { if $0 == nil { linkModel?.cancel() } })) { pending in
                if let linkModel {
                    ClassTableImportConfirmView(model: linkModel, code: pending.code)
                }
            }
            .onChange(of: linkModel?.isFinished) { _, isFinished in
                if isFinished == true { linkModel = nil }
            }
            .task(id: HeldLinkWait(
                link: HeldShareLink.mayOpen(in: app) ? HeldShareLink.shared.link?.id : nil,
                notifySheetUp: app.updateNotifyCoordinator.activeNotifySheet != nil,
                keyWindowChanges: keyWindowChanges
            )) {
                while openHeldLink() == .waitsForTheWindow, hostWindow.isPresenting, !Task.isCancelled {
                    await hostWindow.presentationsClosed()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)) { _ in
                keyWindowChanges += 1
            }
            // Last, so the share sheet shown here can open the scanner too.
            .environment(\.requestClassTableImport) {
                guard importModel == nil else { return }
                importModel = .live(authService: app.authService)
            }
            .environment(\.isUpdatingImportedClassTable, linkModel?.isUpdating == true)
            .readsHostWindow(into: hostWindow)
            .environment(\.hostWindow, hostWindow)
    }

    private func openHeldLink() -> HeldLinkOpening {
        // A link replaces what an open scanner, or an earlier link's import, shows, inside it.
        let inPlace: ClassTableImportModel? = if let importModel, !importModel.isFinished {
            importModel
        } else if let linkModel, !linkModel.isIdle, !linkModel.isFinished {
            linkModel
        } else {
            nil
        }
        if let inPlace {
            if let text = HeldShareLink.shared.take(in: app) { inPlace.linkOpened(text) }
            return .done
        }
        let windowCannotShowTheImport = !hostWindow.mayBeForeground || hostWindow.isPresenting
            || app.updateNotifyCoordinator.activeNotifySheet != nil
        if windowCannotShowTheImport, HeldShareLink.shared.link != nil, HeldShareLink.mayOpen(in: app) {
            return .waitsForTheWindow
        }
        guard let text = HeldShareLink.shared.take(in: app) else { return .done }
        let model = ClassTableImportModel.live(authService: app.authService)
        linkModel = model
        model.linkOpened(text)
        return .done
    }
}

private enum HeldLinkOpening {
    case done
    case waitsForTheWindow
}

private struct HeldLinkWait: Equatable {
    let link: UUID?
    let notifySheetUp: Bool
    let keyWindowChanges: Int
}

private struct ServerPushPopupHost: ViewModifier {
    @Environment(AppEnvironment.self) private var app

    func body(content: Content) -> some View {
        @Bindable var bindable = app.router
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
                    bindable.markServerPopupShown(popup.id)
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
    @Environment(AppEnvironment.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppFeature = .home
    @State private var showTimezoneAlert: Bool = false
    @State private var hostWindow = HostWindow()

    private var visibleTabs: [AppFeature] { app.preferences.configuredTabs }

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
                userName: ClassTableSwitcherEntry.userName(studentId: app.authService.storedStudentId),
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
            app.updateNotifyCoordinator.evaluateWhatsNewOnLaunch(in: app)
            app.updateNotifyCoordinator.checkInBackground()
            #endif
        }
        .onChange(of: app.router.pendingWidgetDestination) { _, _ in
            drainPendingWidgetDestination()
        }
        #if os(iOS)
        .onChange(of: app.router.pendingDeepLink, initial: true) { _, new in
            Self.route(new, in: hostWindow, open: open)
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
        .readsHostWindow(into: hostWindow)
        .environment(\.hostWindow, hostWindow)
        #endif
    }

    private func evaluateTimezoneAlert() {
        if TimezoneObserver.shared.isNonTaipei {
            showTimezoneAlert = true
        }
    }

    #if os(iOS)
    /// An assignment link opens Home at once, as the page it pushes closes the sheets itself.
    static func route(_ link: DeepLink?, in host: HostWindow, open: @escaping (AppFeature) -> Void) {
        switch link {
        case .bulletin: host.closePresentations { _ in open(.announcements) }
        case .schoolMail where SchoolMailAvailability.isEnabled: host.closePresentations { _ in open(.schoolMail) }
        case .assignment: open(.home)
        case .schoolMail, nil: break
        }
    }
    #endif

    private func open(_ feature: AppFeature) {
        let route = AppFeature.tabRoute(to: feature, visibleTabs: visibleTabs)
        selectedTab = route.tab
        if let page = route.moreDeepLink {
            app.router.pendingMoreDeepLink = page
        }
    }

    private func drainPendingWidgetDestination() {
        guard let destination = app.router.pendingWidgetDestination else { return }
        switch destination {
        case .library:
            open(.library)
        case .classTable:
            ImportedClassTableStore.shared.show(nil)
            open(.classTable)
        }
        app.router.clearPendingWidgetDestination()
    }

    @ViewBuilder
    private func viewForFeature(_ feature: AppFeature) -> some View {
        switch feature {
        case .home: HomeView()
        case .classTable: ClassTableView()
        case .calendar: CalendarTabView()
        case .announcements: BulletinsView()
        case .gpa: ScoreView()
        case .informationSystem: InformationSystemView()
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
