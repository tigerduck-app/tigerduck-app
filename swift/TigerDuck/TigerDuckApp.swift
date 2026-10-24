import SwiftUI
import SwiftData
#if os(iOS)
import UserNotifications
#endif

#if os(iOS)

@main
enum TigerDuckLauncher {
    static func main() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            UnitTestHostApp.main()
        } else {
            TigerDuckApp.main()
        }
    }
}

private struct UnitTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            Color.clear
        }
    }
}

struct TigerDuckApp: App {
    struct Built {
        let appState: AppState
        let watchSync: WatchSyncCoordinator
        let widgetSnapshotWriter: WidgetSnapshotWriter
    }

    @State private var launch: AfterFirstUnlock<Built>
    @State private var sceneRefreshTask: Task<Void, Never>?
    @State private var rootLanguageId = UUID()
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushAppDelegate
    @Environment(\.scenePhase) private var scenePhase

    private var appState: AppState { launch.value.appState }
    private var watchSyncCoordinator: WatchSyncCoordinator { launch.value.watchSync }
    private var widgetSnapshotWriter: WidgetSnapshotWriter { launch.value.widgetSnapshotWriter }

    init() {
        // push or a Watch message can launch the app in the background, where no scene appears
        // and `.onAppear` never runs.
        let launch = Self.makeLaunch(hasUnlocked: FirstUnlock.hasHappened(), center: .default)
        _launch = State(initialValue: launch)
        PushAppDelegate.launchWork = { delegate in
            launch.whenBuilt { built in
                if built.appState.hasCompletedOnboarding {
                    built.appState.bindPushDelegate(delegate)
                }
                built.watchSync.activate()
                delegate.beforeAnsweringSyncTrigger = { built.widgetSnapshotWriter.regenerateAndReloadNow() }
                delegate.sendBeforeAnsweringSyncTrigger = { await built.appState.sendPushScheduleAfterSyncTrigger($0) }
            }
        }
    }

    static func makeLaunch(
        hasUnlocked: Bool, center: NotificationCenter, endProcess: @escaping () -> Void = { exit(0) }
    ) -> AfterFirstUnlock<Built> {
        AfterFirstUnlock(hasUnlocked: hasUnlocked, endProcess: endProcess, center: center) {
            let appState = AppState()
            let watchSync = WatchSyncCoordinator()
            #if DEBUG
            MainThreadWatchdog.start()
            DebugClockController.shared.bootstrap()
            #endif
            PushCoordinator.assertEnvConsistency()
            SchoolMailBootstrap.install()
            let widgetSnapshotWriter = WidgetSnapshotWriter(appState: appState)
            watchSync.setPayloadSource { WatchSyncCoordinator.Payload(appState: appState) }
            return Built(appState: appState, watchSync: watchSync, widgetSnapshotWriter: widgetSnapshotWriter)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .id(rootLanguageId)
                .updateRequiredAlert()
                .tint(AccentPreview.shared.tint(saved: appState.accentColor))
                .preferredColorScheme(.dark)
                .background(WatchSyncBridge(coordinator: watchSyncCoordinator))
                .environment(appState)
                .onAppear {
                    watchSyncCoordinator.activate()
                    appState.bindPushDelegate(pushAppDelegate)
                    if let nd = pushAppDelegate.notificationDelegate {
                        let state = appState
                        nd.routeTap = { [weak state] response in
                            Task { @MainActor in
                                Self.routeServerPushTap(
                                    response: response,
                                    appState: state
                                )
                            }
                        }
                    }
                    appState.backgroundSync()
                    appState.startCloudSyncIfEnabled()
                    Task { await LibraryService.signInIfCredentialed() }
                    Task { widgetSnapshotWriter.regenerate() }
                    // `.onChange(of: scenePhase)` does not fire for the initial `.active`
                    // value, so the first background check starts here; later foreground
                    appState.updateNotifyCoordinator.checkInBackground()
                    UNUserNotificationCenter.current().setBadgeCount(0)
                }
                .onOpenURL { url in
                    if let text = ClassTableShareLink.codeText(url) {
                        HeldShareLink.shared.arrived(text, loginGeneration: appState.authService.loginGeneration)
                        appState.openFromWidget(.classTable)
                        return
                    }
                    if let id = WidgetURLRouter.assignmentId(from: url) {
                        appState.pendingDeepLink = .assignment(id)
                        return
                    }
                    guard let destination = WidgetURLRouter.route(url) else { return }
                    appState.openFromWidget(destination)
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: AppConstants.languageDidChange)
                ) { _ in
                    rootLanguageId = UUID()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active: SchoolMailBootstrap.sceneDidBecomeActive()
                    case .background: SchoolMailBootstrap.sceneDidEnterBackground()
                    default: break
                    }
                    if newPhase == .active {
                        UNUserNotificationCenter.current().setBadgeCount(0)
                        Task {
                            if await AcademicCalendarStore.shared.refresh() {
                                await appState.refreshLiveActivity()
                                widgetSnapshotWriter.regenerate()
                            }
                        }
                        sceneRefreshTask?.cancel()
                        sceneRefreshTask = Task {
                            await appState.refreshLiveActivity()
                            guard !Task.isCancelled else { return }
                            appState.requestPushScheduleSync()
                            await appState.refreshMoodleCredentials()
                        }
                        if appState.hasCompletedOnboarding {
                            Task { await AppServiceBridge.refreshAssignmentsIfDue(authService: appState.authService) }
                        }
                        Task { await LibraryService.signInIfCredentialed() }
                        appState.startRevisionPolling()
                        appState.pushCoordinator.registerAgainIfGaveUp()
                        widgetSnapshotWriter.regenerate()
                        appState.updateNotifyCoordinator.checkInBackground()
                    } else if newPhase == .background {
                        appState.stopRevisionPolling()
                    }
                }
        }
        .modelContainer(Self.sharedModelContainer)
    }

    @MainActor
    private static func routeServerPushTap(
        response: UNNotificationResponse,
        appState: AppState?
    ) {
        guard let appState else { return }
        let info = response.notification.request.content.userInfo
        let kind = info["kind"] as? String
        switch kind {
        case "custom_push_bulletin", "bulletin":
            if let link = AppState.bulletinDeepLink(from: info) {
                appState.pendingDeepLink = link
            }
        case "assignment_reminder":
            if let assignment = AppState.remindedAssignment(
                from: info,
                in: DataCache.shared.loadAssignments()
            ) {
                appState.pendingDeepLink = .assignment(assignment.assignmentId)
            }
        case "custom_push_popup":
            guard let nid = info["notification_id"] as? String,
                  let title = info["title"] as? String,
                  let body = info["body"] as? String else { return }
            guard !appState.isServerPopupShown(nid) else { return }
            let payload = AppState.ServerPopupPayload(
                id: nid,
                title: title,
                body: body
            )
            // A popup arriving over a shown alert clears it and presents a tick later, so
            // `.alert(_:isPresented:presenting:)` sees `isPresented` go false → true. Cancel
            appState.pendingServerPopupSwapTask?.cancel()
            appState.pendingServerPopupSwapTask = nil
            if appState.pendingServerPopup != nil {
                appState.pendingServerPopup = nil
                appState.pendingServerPopupSwapTask = Task { @MainActor [weak appState] in
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled, let appState else { return }
                    appState.pendingServerPopup = payload
                    appState.pendingServerPopupSwapTask = nil
                }
            } else {
                appState.pendingServerPopup = payload
            }
        case MailConstants.notificationKind:
            appState.pendingDeepLink = AppState.schoolMailDeepLink(from: info)
        default:
            break
        }
    }
}

#elseif os(macOS)

@main
struct TigerDuckApp: App {
    @State private var appState = AppState()
    @State private var rootLanguageId = UUID()
    @State private var widgetSnapshotWriter: WidgetSnapshotWriter?
    @State private var sceneRefreshTask: Task<Void, Never>?
    @NSApplicationDelegateAdaptor(MacPushAppDelegate.self) private var pushAppDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PushCoordinator.assertEnvConsistency()
    }

    var body: some Scene {
        Window("TigerDuck", id: "main") {
            MacRootView()
                .id(rootLanguageId)
                .updateRequiredAlert()
                .macUpdatePrompt()
                .environment(appState)
                .onAppear {
                    appState.bindPushDelegate(pushAppDelegate)
                    appState.backgroundSync()
                    appState.startCloudSyncIfEnabled()
                    appState.updateNotifyCoordinator.checkInBackground()
                    if widgetSnapshotWriter == nil {
                        widgetSnapshotWriter = WidgetSnapshotWriter(appState: appState)
                        widgetSnapshotWriter?.regenerate()
                    }
}
                .onOpenURL { url in
                    if let text = ClassTableShareLink.codeText(url) {
                        HeldShareLink.shared.arrived(text, loginGeneration: appState.authService.loginGeneration)
                        appState.openFromWidget(.classTable)
                        return
                    }
                    guard let destination = WidgetURLRouter.route(url) else { return }
                    appState.openFromWidget(destination)
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: AppConstants.languageDidChange)
                ) { _ in
                    rootLanguageId = UUID()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task {
                            if await AcademicCalendarStore.shared.refresh() {
                                widgetSnapshotWriter?.regenerate()
                            }
                        }
                        sceneRefreshTask?.cancel()
                        sceneRefreshTask = Task {
                            appState.requestPushScheduleSync()
                            await appState.refreshMoodleCredentials()
                        }
                        if appState.hasCompletedOnboarding {
                            Task { await AppServiceBridge.refreshAssignmentsIfDue(authService: appState.authService) }
                        }
                        appState.startRevisionPolling()
                        appState.pushCoordinator.registerAgainIfGaveUp()
                        widgetSnapshotWriter?.regenerate()
                        appState.updateNotifyCoordinator.checkInBackground()
                    } else if newPhase == .background {
                        appState.stopRevisionPolling()
                    }
                }
        }
        .modelContainer(Self.sharedModelContainer)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                MacCheckForUpdatesCommand(coordinator: appState.updateNotifyCoordinator)
            }
        }

        Settings {
            MacSettingsScene()
                .environment(appState)
        }

        Window(String(localized: "settings_open_source_licenses"), id: MacLicensesView.windowID) {
            MacLicensesView()
                // Rebuild on a language change, as the main window does: String(localized:)
                // resolves once. The title follows through the navigationTitle inside; the
                // Window menu name is the scene's own and stays until relaunch.
                .id(rootLanguageId)
                .environment(appState)
                // Environments do not cross scene boundaries, so this window gets neither
                // MacSettingsScene's tint nor the main window's; without this its links
                // would use the system accent instead of the chosen one.
                .tint(AccentPreview.shared.tint(saved: appState.accentColor))
                .onReceive(
                    NotificationCenter.default.publisher(for: AppConstants.languageDidChange)
                ) { _ in
                    rootLanguageId = UUID()
                }
        }
        .defaultSize(width: 900, height: 600)
    }
}

#endif

extension TigerDuckApp {
    /// `static` so the store is opened once per process: SwiftData expects one `ModelContainer`
    /// per on-disk store, and the open (disk and schema check) runs in front of the first frame.
    static let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SDCourse.self,
            SDAssignment.self,
            SDAnnouncement.self,
            SDCalendarEvent.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            AppLogger.captureError(error, context: ["phase": "modelContainer.initialCreate"])
            deleteStoreFiles(at: modelConfiguration.url)
            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                AppLogger.captureError(error, context: ["phase": "modelContainer.retryAfterReset"])
                do {
                    let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                    return try ModelContainer(for: schema, configurations: [memoryConfig])
                } catch {
                    AppLogger.captureError(error, context: ["phase": "modelContainer.inMemoryFallback"])
                    fatalError("Could not create ModelContainer (on-disk reset and in-memory both failed): \(error)")
                }
            }
        }
    }()

    /// Deletes the store and its SQLite sidecars. SQLite names them by appending "-wal" and
    /// "-shm" to the store's file name (`default.store-wal`); one left behind hands the retry
    /// the same stale data.
    static func deleteStoreFiles(at storeURL: URL) {
        let files = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
        ]
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
