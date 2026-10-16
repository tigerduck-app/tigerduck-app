import SwiftUI
import SwiftData
#if os(iOS)
import UserNotifications
#endif

#if os(iOS)

/// Unit tests run inside the app, and XCTest sets `XCTestConfigurationFilePath` there. They get
/// an empty scene: `TigerDuckApp`'s launch work would sync a signed-in simulator with the school,
/// write real Defaults and hold the main actor while the tests run.
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

/// A window and nothing else, so hosted-view tests still find a scene in
/// `UIApplication.shared.connectedScenes`.
private struct UnitTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            Color.clear
        }
    }
}

struct TigerDuckApp: App {
    @State private var appState: AppState
    @State private var sceneRefreshTask: Task<Void, Never>?
    @State private var rootLanguageId = UUID()
    @State private var widgetSnapshotWriter: WidgetSnapshotWriter
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushAppDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var watchSyncCoordinator: WatchSyncCoordinator

    init() {
        // Built here, not as property defaults, so the launch work below can hold them. A silent
        // push or a Watch message can launch the app in the background, where no scene appears
        // and `.onAppear` never runs.
        let appState = AppState()
        let watchSync = WatchSyncCoordinator()
        _appState = State(initialValue: appState)
        _watchSyncCoordinator = State(initialValue: watchSync)
        #if DEBUG
        // Scaffolding for the Library freeze: tells a blocked main thread
        // apart from swallowed touches, which a spinning ProgressView
        // cannot. See MainThreadWatchdog.
        MainThreadWatchdog.start()
        // Apply any persisted clock override before any UI reads the clock,
        // so view models constructed during the first render see the right
        // "now". Entire branch compiles out in Release.
        DebugClockController.shared.bootstrap()
        #endif
        PushCoordinator.assertEnvConsistency()
        SchoolMailBootstrap.install()
        _widgetSnapshotWriter = State(initialValue: WidgetSnapshotWriter(appState: appState))
        watchSync.setPayloadSource { WatchSyncCoordinator.Payload(appState: appState) }
        // Sync triggers reach the backend, so they wait for onboarding as `AppState.init` does;
        // `.onAppear` binds them again for a user who finishes onboarding in this session.
        PushAppDelegate.launchWork = { delegate in
            if appState.hasCompletedOnboarding {
                appState.bindPushDelegate(delegate)
            }
            watchSync.activate()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .id(rootLanguageId)
                .updateRequiredAlert()
                .tint(appState.accentColor)
                .preferredColorScheme(.dark)
                .background(WatchSyncBridge(coordinator: watchSyncCoordinator))
                .environment(appState)
                .onAppear {
                    watchSyncCoordinator.activate()
                    appState.bindPushDelegate(pushAppDelegate)
                    // Route custom-push taps into AppState. Capture the
                    // class instance weakly to avoid a retain cycle
                    // through `pushAppDelegate.notificationDelegate`.
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
                    // A turn later, behind the first frame: the snapshot reads every cache it
                    // draws from and writes the App Group file.
                    Task { widgetSnapshotWriter.regenerate() }
                    // `.onChange(of: scenePhase)` does not fire for the initial `.active`
                    // value, so the first background check starts here; later foreground
                    // returns go through the scene-phase observer.
                    appState.updateNotifyCoordinator.checkInBackground()
                    UNUserNotificationCenter.current().setBadgeCount(0)
                }
                .onOpenURL { url in
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
                        // Clear the app-icon badge but keep delivered notifications
                        // in Notification Center, so the user can still scroll back
                        // to them once the app is open.
                        UNUserNotificationCenter.current().setBadgeCount(0)
                        // Calendar refresh is not gated on sign-in or cloud sync: holiday reminder
                        // suppression must depend on neither. A change redraws the Live Activity
                        // and widgets.
                        Task {
                            if await AcademicCalendarStore.shared.refresh() {
                                await appState.refreshLiveActivity()
                                widgetSnapshotWriter.regenerate()
                            }
                        }
                        // Cancel the previous activation's refresh so rapid scene toggles do not
                        // repeat its push sync and Moodle credential work.
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
                        // The library token lasts a day, so a return after one signs in again here.
                        Task { await LibraryService.signInIfCredentialed() }
                        appState.startRevisionPolling()
                        appState.pushCoordinator.registerAgainIfGaveUp()
                        widgetSnapshotWriter.regenerate()
                        // App Store update check, throttled inside to once per
                        // ``AppConstants/updateCheckThrottle`` so rapid scene
                        // toggles don't generate iTunes Lookup traffic.
                        appState.updateNotifyCoordinator.checkInBackground()
                    } else if newPhase == .background {
                        appState.stopRevisionPolling()
                    }
                }
        }
        .modelContainer(Self.sharedModelContainer)
    }

    /// Translates a tapped notification into the right AppState mutation. A
    /// static helper keeps the SwiftUI body uncluttered; the payload parsing it
    /// calls lives in AppState+PushRouting.swift, where it is unit-tested.
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
            // Only check here: `ServerPushPopupHost` marks the popup shown when the
            // user dismisses it, so a popup hidden by a competing modal (such as
            // onboarding) is not deduped before the user ever sees it.
            guard !appState.isServerPopupShown(nid) else { return }
            let payload = AppState.ServerPopupPayload(
                id: nid,
                title: title,
                body: body
            )
            // A popup arriving over a shown alert clears it and presents a tick later, so
            // `.alert(_:isPresented:presenting:)` sees `isPresented` go false → true. Cancel
            // any pending swap first, or the stale task would overwrite the newer payload.
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
            // Unknown / legacy kinds fall through to the OS default open
            // behaviour — no-op here so we don't accidentally swallow them.
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
                        // Calendar refresh is not gated on sign-in or cloud sync: holiday reminder
                        // suppression must depend on neither. Only widgets redraw on a change:
                        // `AppState+LiveActivity.swift` is not compiled for macOS.
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
                        // Throttled to a day inside; a return to the app
                        // is when a new App Store version is worth telling.
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

        // Its own window rather than a page inside Settings: that window is
        // fixed-size with no navigation stack, and licence texts are long.
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
                .tint(appState.accentColor)
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
            // Schema incompatible with existing store (e.g. upgrade from early version).
            // Delete the old store and retry.
            deleteStoreFiles(at: modelConfiguration.url)
            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                AppLogger.captureError(error, context: ["phase": "modelContainer.retryAfterReset"])
                // A full disk, a locked sandbox path or a file-coordination failure ends up
                // here; crashing would brick every launch. An in-memory container shows an
                // empty state for this session, and the next launch retries on disk.
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
