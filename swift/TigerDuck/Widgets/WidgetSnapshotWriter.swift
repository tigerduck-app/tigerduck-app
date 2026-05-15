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

    init(
        appState: AppState,
        cache: DataCache = .shared,
        store: WidgetSnapshotStore = WidgetSnapshotStore(),
        coordinator: WidgetReloadCoordinator = WidgetReloadCoordinator(),
        courseProvider: CanonicalCourseProvider = CanonicalCourseProvider()
    ) {
        self.appState = appState
        self.cache = cache
        self.store = store
        self.coordinator = coordinator
        self.courseProvider = courseProvider
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
        let customNames = cache.loadCourseCustomNames()
        let snapshot = WidgetSnapshotBuilder.build(
            .init(
                courses: courses,
                customNames: customNames,
                isLoggedIn: appState.isNTUSTLoggedIn,
                accentColorHex: UInt32(bitPattern: Int32(truncatingIfNeeded: appState.accentColorHex)),
                now: Date()
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
