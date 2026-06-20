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
        // Apply any persisted clock override before any UI reads the clock,
        // so view models constructed during the first render see the right
        // "now". Entire branch compiles out in Release.
        DebugClockController.shared.bootstrap()
        #endif
        PushCoordinator.assertEnvConsistency()
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
                    if widgetSnapshotWriter == nil {
                        widgetSnapshotWriter = WidgetSnapshotWriter(appState: appState)
                        widgetSnapshotWriter?.regenerate()
                    }
                    // First-launch path. `.onChange(of: scenePhase)` does
                    // not fire for the initial `.active` value, so the
                    // first background check needs an explicit kickoff
                    // here; subsequent foreground returns go through the
                    // scene-phase observer.
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
                    if newPhase == .active {
                        // Reset the app-icon badge but leave delivered
                        // notifications in Notification Center — user can
                        // still scroll back to them, the red badge just
                        // stops nagging once they've opened the app.
                        UNUserNotificationCenter.current().setBadgeCount(0)
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
                            await appState.refreshMoodleCredentials()
                        }
                        appState.startRevisionPolling()
                        widgetSnapshotWriter?.regenerate()
                        // Background "is there a newer build on the App
                        // Store?" check. Internally throttled to once
                        // per ``AppConstants/updateCheckThrottle`` so
                        // rapid scene toggles don't generate iTunes
                        // Lookup traffic.
                        appState.updateNotifyCoordinator.checkInBackground()
                    } else if newPhase == .background {
                        appState.stopRevisionPolling()
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }

    /// Translates a tapped notification into the right AppState mutation.
    /// Kept as a static helper so the SwiftUI body stays uncluttered and
    /// the routing logic can be unit-tested independently of the App
    /// scene plumbing.
    ///
    /// - Note: `bulletin_id` is decoded through three paths (`Int`,
    ///   `NSNumber.intValue`, and `String → Int`) because APNs / FCM /
    ///   intermediate relays bridge JSON numbers inconsistently — some
    ///   land as a tagged-int NSNumber that succeeds `as? Int`, others
    ///   as a Double-tagged NSNumber where `as? Int` fails, and a few
    ///   re-encode the value as a quoted string.
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
            // Only the *check* runs at routing time — the actual mark
            // happens when the user dismisses the alert (see
            // `ServerPushPopupHost`). That way a popup that's suppressed
            // by a competing modal (mid-onboarding etc.) isn't permanently
            // deduped before the user ever sees it.
            guard !appState.isServerPopupShown(nid) else { return }
            let payload = AppState.ServerPopupPayload(
                id: nid,
                title: title,
                body: body
            )
            // Force SwiftUI's `.alert(_:isPresented:presenting:)` to
            // refresh when a second popup arrives while the first alert
            // is still on screen: dismiss the current alert, then present
            // the new payload on the next runloop tick so `isPresented`
            // actually transitions false → true.
            //
            // Always cancel any previous swap first — if popup B's swap
            // is mid-sleep when popup C arrives, the stale B task would
            // otherwise wake up and overwrite C's payload with B's.
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
        PushCoordinator.assertEnvConsistency()
    }

    var body: some Scene {
        Window("TigerDuck", id: "main") {
            MacRootView()
                .id(rootLanguageId)
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
                        sceneRefreshTask?.cancel()
                        sceneRefreshTask = Task {
                            appState.requestPushScheduleSync()
                            await appState.refreshMoodleCredentials()
                        }
                        appState.startRevisionPolling()
                        widgetSnapshotWriter?.regenerate()
                    } else if newPhase == .background {
                        appState.stopRevisionPolling()
                    }
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
