import SwiftUI
import SwiftData

#if os(iOS)

@main
struct TigerDuckApp: App {
    @State private var appState = AppState()
    @State private var sceneRefreshTask: Task<Void, Never>?
    @State private var rootLanguageId = UUID()
    @State private var widgetSnapshotWriter: WidgetSnapshotWriter?
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushAppDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let watchSyncCoordinator = WatchSyncCoordinator()

    init() {
        AppLogger.start()
        #if DEBUG
        // Apply any persisted clock override before any UI reads the clock,
        // so view models constructed during the first render see the right
        // "now". Entire branch compiles out in Release.
        DebugClockController.shared.bootstrap()
        #endif
        PushCoordinator.assertEnvConsistency()
        watchSyncCoordinator.activate()
    }

    var sharedModelContainer: ModelContainer = {
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
                // Disk full / sandbox path locked / file-coordination
                // failure all hardfault here, which would brick the app
                // on launch with no recovery path. Fall back to an
                // in-memory container so the app still launches; the
                // user sees an empty state for one session, the next
                // launch retries an on-disk container.
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
                .tint(appState.accentColor)
                .preferredColorScheme(.dark)
                .background(WatchSyncBridge(coordinator: watchSyncCoordinator))
                .environment(appState)
                .onAppear {
                    appState.bindPushDelegate(pushAppDelegate)
                    appState.backgroundSync()
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
                        // Cancel any still-running refresh from a previous
                        // .active transition so rapid scene toggles do not
                        // interleave through cancelAllOwnedRequests()'s
                        // await suspension point and double the reschedule.
                        sceneRefreshTask?.cancel()
                        sceneRefreshTask = Task {
                            await appState.refreshLiveActivity()
                            guard !Task.isCancelled else { return }
                            await appState.rescheduleReminders()
                            appState.requestPushScheduleSync()
                        }
                        widgetSnapshotWriter?.regenerate()
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}

#elseif os(macOS)

@main
struct TigerDuckApp: App {
    @State private var appState = AppState()
    @State private var rootLanguageId = UUID()
    @State private var widgetSnapshotWriter: WidgetSnapshotWriter?

    var sharedModelContainer: ModelContainer = {
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
            // SQLite sidecars use a "-wal" / "-shm" suffix on the full
            // store filename (e.g. `default.store-wal`), not a
            // dot-extension — `appendingPathExtension` would target
            // `default.store.wal`, leaving the real sidecars behind and
            // letting the retry hit the same stale data.
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
    }

    var body: some Scene {
        Window("TigerDuck", id: "main") {
            MacRootView()
                .id(rootLanguageId)
                .environment(appState)
                .onAppear {
                    // Mirror the iOS launch path: kick off the first
                    // sync so Home/Class Table/Calendar don't sit on
                    // stale cache until the user hits Refresh.
                    appState.backgroundSync()
                    // Widget extension reads its snapshot from the App
                    // Group. Without this regenerate the Mac widget
                    // would render the "Please sign in" placeholder
                    // even when credentials exist — the writer pipeline
                    // is what fills the snapshot store on iPhone and
                    // we mirror it here.
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
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            MacSettingsScene()
                .environment(appState)
        }
    }
}

#endif
