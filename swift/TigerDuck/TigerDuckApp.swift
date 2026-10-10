import SwiftUI
import SwiftData
#if os(iOS)
import UserNotifications
#endif

#if os(iOS)

@main
struct TigerDuckApp: App {
    @State private var appState = AppState()
    @State private var sceneRefreshTask: Task<Void, Never>?
    @State private var rootLanguageId = UUID()
    @State private var widgetSnapshotWriter: WidgetSnapshotWriter?
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushAppDelegate
    @Environment(\.scenePhase) private var scenePhase

    @State private var watchSyncCoordinator = WatchSyncCoordinator()
    @State private var watchSyncActivated = false

    init() {
        AppLogger.start()
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
    }

    /// `static` so the store is opened exactly once per process. As an
    /// instance property this was rebuilt on every `App` initialisation —
    /// SwiftData expects a single `ModelContainer` per on-disk store, and
    /// the open (disk + schema compatibility check) is synchronous work
    /// sitting directly in front of the first frame.
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
            let storeURL = modelConfiguration.url
            let relatedFiles = [
                storeURL,
                storeURL.appendingPathExtension("wal"),
                storeURL.appendingPathExtension("shm"),
            ]
            for file in relatedFiles {
                try? FileManager.default.removeItem(at: file)
            }
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
                    if !watchSyncActivated {
                        watchSyncActivated = true
                        watchSyncCoordinator.activate()
                    }
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
                    if widgetSnapshotWriter == nil {
                        widgetSnapshotWriter = WidgetSnapshotWriter(appState: appState)
                        widgetSnapshotWriter?.regenerate()
                    }
                    // `.onChange(of: scenePhase)` does not fire for the initial `.active`
                    // value, so the first background check starts here; later foreground
                    // returns go through the scene-phase observer.
                    appState.updateNotifyCoordinator.checkInBackground()
                    UNUserNotificationCenter.current().setBadgeCount(0)
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
                                widgetSnapshotWriter?.regenerate()
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
                        appState.startRevisionPolling()
                        widgetSnapshotWriter?.regenerate()
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
    /// static helper keeps the SwiftUI body uncluttered and lets the routing
    /// be unit-tested without the App scene plumbing.
    ///
    /// `bulletin_id` is decoded as `Int`, `NSNumber.intValue` and `String → Int`
    /// because APNs, FCM and relays bridge JSON numbers inconsistently: an
    /// int-tagged NSNumber passes `as? Int`, a Double-tagged one fails it, and
    /// some relays re-encode the value as a quoted string.
    @MainActor
    private static func routeServerPushTap(
        response: UNNotificationResponse,
        appState: AppState?
    ) {
        guard let appState else { return }
        let info = response.notification.request.content.userInfo
        let kind = info["kind"] as? String
        switch kind {
        case "custom_push_bulletin":
            if let id = bulletinId(from: info["bulletin_id"]) {
                appState.pendingDeepLink = .bulletin(id)
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

    /// Decode `bulletin_id` from a JSON-bridged userInfo value. See the
    /// `routeServerPushTap` doc comment for why all three paths exist.
    @MainActor
    private static func bulletinId(from raw: Any?) -> Int? {
        if let n = raw as? Int { return n }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
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

    /// `static` so the store is opened exactly once per process. As an
    /// instance property this was rebuilt on every `App` initialisation —
    /// SwiftData expects a single `ModelContainer` per on-disk store, and
    /// the open (disk + schema compatibility check) is synchronous work
    /// sitting directly in front of the first frame.
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
            // Same on-disk-reset → in-memory fallback chain the iOS branch
            // uses.
            let storeURL = modelConfiguration.url
            // SQLite sidecars append "-wal" / "-shm" to the full store filename
            // (`default.store-wal`); `appendingPathExtension` would target
            // `default.store.wal` and leave them, so the retry hits the same stale data.
            let relatedFiles = [
                storeURL,
                URL(fileURLWithPath: storeURL.path + "-wal"),
                URL(fileURLWithPath: storeURL.path + "-shm"),
            ]
            for file in relatedFiles {
                try? FileManager.default.removeItem(at: file)
            }
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

    init() {
        AppLogger.start()
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
