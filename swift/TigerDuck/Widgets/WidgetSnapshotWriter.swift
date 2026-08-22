import Foundation
import os

/// Owns the widget snapshot write pipeline. Listens for the existing app-side
/// notifications that signal state worth reflecting in widgets (data refresh
/// completion, language change, system locale change), rebuilds the snapshot
/// via `WidgetSnapshotBuilder`, persists it through the App Group store, and
/// asks `WidgetReloadCoordinator` to refresh widget timelines (debounced).
///
/// Not auto-wired: the host app explicitly creates this and calls
/// `regenerate()` at cold-start; thereafter the observer paths drive
/// regeneration. Called paths are deliberately coarse — `regenerate()`
/// rebuilds the entire snapshot every time. Coupled with the coordinator's
/// 300 ms debounce, this is acceptable for v1; if profiling shows the
/// rebuild cost is meaningful we can split into per-source paths later.
///
/// Known gap: accent-color changes in `AppState` do NOT post a notification
/// today, so a pure accent tweak won't trigger a regeneration on its own.
/// The next observed event (data sync, language change, locale change, or
/// any explicit `regenerate()` call) will pick up the new accent. Wire an
/// explicit notification post when/if this becomes user-visible.
@MainActor
final class WidgetSnapshotWriter {
    private let store: WidgetSnapshotStore
    private let coordinator: WidgetReloadCoordinator
    private let appState: AppState
    private let courseProvider: CanonicalCourseProvider
    private let cache: DataCache
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "WidgetWriter")

    private var observers: [NSObjectProtocol] = []

    // Defaults are resolved in the init body rather than as parameter
    // default expressions because `DataCache.shared` and the nested
    // `WidgetReloadCoordinator()` factory call land in MainActor-isolated
    // code; under Swift 6 strict concurrency parameter default
    // expressions evaluate in a nonisolated context even on a
    // MainActor-isolated init, so the MainActor references warn there.
    init(
        appState: AppState,
        cache: DataCache? = nil,
        store: WidgetSnapshotStore? = nil,
        coordinator: WidgetReloadCoordinator? = nil,
        courseProvider: CanonicalCourseProvider? = nil
    ) {
        self.appState = appState
        self.cache = cache ?? .shared
        self.store = store ?? WidgetSnapshotStore()
        self.coordinator = coordinator ?? WidgetReloadCoordinator()
        self.courseProvider = courseProvider ?? CanonicalCourseProvider()
        attachObservers()
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Idempotent — call at app cold-start and again whenever you want to
    /// force a fresh snapshot. Observer paths call this internally.
    func regenerate() {
        let courses = courseProvider.currentCourses()
        let customNames = cache.loadCourseCustomNamesFlat()
        let colorMap = cache.loadCourseColorMap()
        let snapshot = WidgetSnapshotBuilder.build(
            .init(
                courses: courses,
                customNames: customNames,
                colorMap: colorMap,
                // Gate widget UI on stored credentials, not live session
                // state: `isNTUSTLoggedIn` flips false the moment session
                // cookies TTL, which would falsely flash the "Please sign in"
                // empty state on the widget even though the next sync will
                // silently re-authenticate. Matches `ntustProtectedAccessState`.
                isLoggedIn: appState.authService.hasStoredCredentials,
                accentColorHex: UInt32(bitPattern: Int32(truncatingIfNeeded: appState.accentColorHex)),
                now: AppClock.now()
            )
        )
        store.writeSnapshot(snapshot)
        coordinator.requestReload()
    }

    private func attachObservers() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            AppConstants.dataDidUpdate,
            AppConstants.languageDidChange,
            AppConstants.courseSkipStateDidChange,
            AppConstants.courseColorMapDidChange,
            NSLocale.currentLocaleDidChangeNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Hop to the writer's MainActor before touching any state. The
                // notification queue is .main, but we can still bounce through
                // a Task to satisfy strict concurrency on touching the writer
                // from the closure context.
                Task { @MainActor [weak self] in
                    self?.regenerate()
                }
            }
            observers.append(token)
        }
    }
}
