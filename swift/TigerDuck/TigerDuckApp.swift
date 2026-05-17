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

// Stub Mac entry point. Native macOS port is in progress on feat/macos-native:
// the iOS app sources are excluded from the macOS build via
// EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*] so that the Mac destination compiles
// while the per-feature port lands incrementally.
@main
struct TigerDuckApp: App {
    var body: some Scene {
        Window("TigerDuck", id: "main") {
            VStack(spacing: 16) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("TigerDuck for Mac")
                    .font(.largeTitle)
                    .bold()
                Text("Native macOS support is in active development.")
                    .foregroundStyle(.secondary)
                Text("Open the iOS app in the meantime — your data syncs automatically once Mac ships.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .frame(minWidth: 480, minHeight: 320)
            .padding(32)
        }
        .windowResizability(.contentSize)
        .commands {
            // Hide the "New Window" item — there is only one stub window today.
            CommandGroup(replacing: .newItem) {}
        }
    }
}

#endif
