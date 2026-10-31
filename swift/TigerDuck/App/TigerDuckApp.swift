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
        let app: AppEnvironment
        let watchSync: WatchSyncCoordinator
        let widgetSnapshotWriter: WidgetSnapshotWriter
        let deviceSurfaces: DeviceSurfaceSyncer
    }

    @State private var launch: AfterFirstUnlock<Built>
    @State private var rootLanguageId = UUID()
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushAppDelegate
    @Environment(\.scenePhase) private var scenePhase

    private var app: AppEnvironment { launch.value.app }
    private var watchSyncCoordinator: WatchSyncCoordinator { launch.value.watchSync }
    private var widgetSnapshotWriter: WidgetSnapshotWriter { launch.value.widgetSnapshotWriter }

    init() {
        TLSPinEngine.installAppHooks()
        // push or a Watch message can launch the app in the background, where no scene appears
        // and `.onAppear` never runs.
        let launch = Self.makeLaunch(hasUnlocked: FirstUnlock.hasHappened(), center: .default)
        _launch = State(initialValue: launch)
        PushAppDelegate.launchWork = { delegate in
            launch.whenBuilt { built in
                if built.app.hasCompletedOnboarding {
                    built.app.pushSchedule.bindPushDelegate(delegate)
                }
                built.watchSync.activate()
                delegate.beforeAnsweringSyncTrigger = { built.widgetSnapshotWriter.regenerateAndReloadNow() }
                delegate.sendBeforeAnsweringSyncTrigger = { await built.app.pushSchedule.sendAfterSyncTrigger($0) }
            }
        }
    }

    static func makeLaunch(
        hasUnlocked: Bool, center: NotificationCenter, endProcess: @escaping () -> Void = { exit(0) }
    ) -> AfterFirstUnlock<Built> {
        AfterFirstUnlock(hasUnlocked: hasUnlocked, endProcess: endProcess, center: center) {
            let app = AppEnvironment()
            let watchSync = WatchSyncCoordinator()
            #if DEBUG
            MainThreadWatchdog.start()
            DebugClockController.shared.bootstrap()
            #endif
            PushCoordinator.assertEnvConsistency()
            SchoolMailBootstrap.install()
            let widgetSnapshotWriter = WidgetSnapshotWriter(app: app)
            watchSync.setPayloadSource { WatchSyncCoordinator.Payload(app: app) }
            let deviceSurfaces = DeviceSurfaceSyncer(
                surfaces: .init(
                    widgets: { widgetSnapshotWriter.regenerate(forceReload: $0) },
                    watch: { watchSync.pushCurrentState() },
                    liveActivity: { app.liveActivity.scheduleRefresh(after: .zero) }
                ),
                fingerprint: { DeviceSurfaceSyncer.fingerprint(of: app, nudges: $0) }
            )
            return Built(
                app: app, watchSync: watchSync, widgetSnapshotWriter: widgetSnapshotWriter,
                deviceSurfaces: deviceSurfaces
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .id(rootLanguageId)
                .updateRequiredAlert()
                .linkRouting()
                .tlsPinPrompt()
                .tint(AccentPreview.shared.tint(saved: app.preferences.accentColor))
                .appAppearance()
                .environment(app)
                .onAppear {
                    watchSyncCoordinator.activate()
                    watchSyncCoordinator.pushCurrentState()
                    app.pushSchedule.bindPushDelegate(pushAppDelegate)
                    if let nd = pushAppDelegate.notificationDelegate {
                        let router = app.router
                        nd.routeTap = { [weak router] response in
                            Task { @MainActor in
                                router?.openNotification(response.notification.request.content.userInfo) {
                                    AssignmentStore.shared.loadAssignments()
                                }
                            }
                        }
                    }
                    app.activation.sceneAppeared()
                    Task { widgetSnapshotWriter.regenerate() }
                    UNUserNotificationCenter.current().setBadgeCount(0)
                    TLSPinMismatchQueue.shared.isForeground = true
                    fetchPinDocumentIfDue()
                }
                .onOpenURL { url in
                    app.router.open(url, signIn: app.authService.session.ticket)
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: AppConstants.languageDidChange)
                ) { _ in
                    rootLanguageId = UUID()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: AppConstants.tlsPinAcceptanceDidChange)
                ) { _ in
                    sceneDidBecomeActive()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    TLSPinMismatchQueue.shared.isForeground = newPhase != .background
                    if newPhase == .active {
                        sceneDidBecomeActive()
                    } else if newPhase == .background {
                        SchoolMailBootstrap.sceneDidEnterBackground()
                        app.activation.enteredBackground()
                    }
                }
        }
        .modelContainer(Self.sharedModelContainer)
    }

    private func sceneDidBecomeActive() {
        SchoolMailBootstrap.sceneDidBecomeActive()
        UNUserNotificationCenter.current().setBadgeCount(0)
        Task {
            if await AcademicCalendarStore.shared.refresh() {
                await app.liveActivity.refresh()
                widgetSnapshotWriter.regenerate()
            }
        }
        app.activation.becameActive()
        widgetSnapshotWriter.regenerate()
        fetchPinDocumentIfDue()
    }
}

#elseif os(macOS)

@main
struct TigerDuckApp: App {
    @State private var app = AppEnvironment()
    @State private var rootLanguageId = UUID()
    @State private var widgetSnapshotWriter: WidgetSnapshotWriter?
    @State private var deviceSurfaces: DeviceSurfaceSyncer?
    @NSApplicationDelegateAdaptor(MacPushAppDelegate.self) private var pushAppDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PushCoordinator.assertEnvConsistency()
        TLSPinEngine.installAppHooks()
    }

    var body: some Scene {
        Window("TigerDuck", id: "main") {
            MacRootView()
                .id(rootLanguageId)
                .updateRequiredAlert()
                .macUpdatePrompt()
                .environment(app)
                .appAppearance()
                .onAppear {
                    app.pushSchedule.bindPushDelegate(pushAppDelegate)
                    app.activation.sceneAppeared()
                    if widgetSnapshotWriter == nil {
                        let writer = WidgetSnapshotWriter(app: app)
                        widgetSnapshotWriter = writer
                        writer.regenerate()
                        deviceSurfaces = DeviceSurfaceSyncer(
                            surfaces: .init(widgets: { writer.regenerate(forceReload: $0) }),
                            fingerprint: { [app] in DeviceSurfaceSyncer.fingerprint(of: app, nudges: $0) }
                        )
                    }
                    TLSPinMismatchQueue.shared.isForeground = true
                    fetchPinDocumentIfDue()
                }
                .onOpenURL { url in
                    app.router.open(url, signIn: app.authService.session.ticket)
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: AppConstants.languageDidChange)
                ) { _ in
                    rootLanguageId = UUID()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: AppConstants.tlsPinAcceptanceDidChange)
                ) { _ in
                    sceneDidBecomeActive()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    TLSPinMismatchQueue.shared.isForeground = newPhase != .background
                    if newPhase == .active {
                        sceneDidBecomeActive()
                    } else if newPhase == .background {
                        app.activation.enteredBackground()
                    }
                }
        }
        .modelContainer(Self.sharedModelContainer)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                MacCheckForUpdatesCommand(coordinator: app.updateNotifyCoordinator)
            }
        }

        Settings {
            MacSettingsScene()
                .environment(app)
                .appAppearance()
        }

        Window(String(localized: "settings_open_source_licenses"), id: MacLicensesView.windowID) {
            MacLicensesView()
                // Rebuild on a language change, as the main window does: String(localized:)
                // resolves once. The title follows through the navigationTitle inside; the
                // Window menu name is the scene's own and stays until relaunch.
                .id(rootLanguageId)
                .environment(app)
                // Environments do not cross scene boundaries, so this window gets neither
                // MacSettingsScene's tint nor the main window's; without this its links
                // would use the system accent instead of the chosen one.
                .tint(AccentPreview.shared.tint(saved: app.preferences.accentColor))
                .appAppearance()
                .onReceive(
                    NotificationCenter.default.publisher(for: AppConstants.languageDidChange)
                ) { _ in
                    rootLanguageId = UUID()
                }
        }
        .defaultSize(width: 900, height: 600)
    }

    private func sceneDidBecomeActive() {
        Task {
            if await AcademicCalendarStore.shared.refresh() {
                widgetSnapshotWriter?.regenerate()
            }
        }
        app.activation.becameActive()
        widgetSnapshotWriter?.regenerate()
        fetchPinDocumentIfDue()
    }
}

#endif

extension TigerDuckApp {
    /// The pin document is on the TigerDuck backend, which launch code reaches only after onboarding.
    private func fetchPinDocumentIfDue() {
        guard app.hasCompletedOnboarding else { return }
        Task { await TLSPinDocumentFetcher.shared.fetchIfDue() }
    }

    /// `static` so the store is opened once per process: SwiftData expects one `ModelContainer`
    /// per on-disk store, and the open (disk and schema check) runs in front of the first frame.
    static let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SDCourse.self,
            SDAssignment.self,
            SDAnnouncement.self,
            SDCalendarEvent.self,
        ])
        let onDisk = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return openStore(at: onDisk.url) { inMemory in
            try ModelContainer(for: schema, configurations: [
                inMemory ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true) : onDisk,
            ])
        }
    }()

    /// A store that fails to open is deleted and made again only when its file opens: one that
    /// does not, as before the first unlock after a restart, may read later, so this process keeps
    /// its data in memory instead (https://github.com/tigerduck-app/tigerduck-app/issues/693).
    static func openStore<Store>(at storeURL: URL, open: (_ inMemory: Bool) throws -> Store) -> Store {
        do {
            return try open(false)
        } catch {
            AppLogger.captureError(error, context: ["phase": "modelContainer.initialCreate"])
        }
        if !cannotOpenYet(storeURL) {
            deleteStoreFiles(at: storeURL)
            do {
                return try open(false)
            } catch {
                AppLogger.captureError(error, context: ["phase": "modelContainer.retryAfterReset"])
            }
        }
        do {
            return try open(true)
        } catch {
            AppLogger.captureError(error, context: ["phase": "modelContainer.inMemoryFallback"])
            fatalError("Could not create ModelContainer, on disk or in memory: \(error)")
        }
    }

    private static func cannotOpenYet(_ storeURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: storeURL) else { return true }
        try? handle.close()
        return false
    }

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
