import SwiftUI

/// Hidden view that observes the phone's user-facing state (courses, accent
/// color, language, login flag) and pushes a fresh `WatchSnapshot` whenever
/// any of them changes. Lives in the view tree so the `@Observable` `AppState`
/// reactivity drives pushes for free — TigerDuckApp hands us the activated
/// `WatchSyncCoordinator` via init.
///
/// Courses are read through `CanonicalCourseProvider` rather than a
/// SwiftData `@Query`: this app caches the course list in `DataCache` files
/// and never inserts `SDCourse` rows into the model container, so a `@Query`
/// here would always return `[]`. Course-list changes are surfaced via
/// `AppConstants.dataDidUpdate` (posted by `AppState.backgroundSync` after
/// `DataCache.saveCourses`) — the bridge re-reads on that notification.
struct WatchSyncBridge: View {

    @Environment(AppState.self) private var appState

    let coordinator: WatchSyncCoordinator
    private let courseProvider = CanonicalCourseProvider()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            // Pump once on appear so the watch gets the current state even
            // when nothing's mutated since launch.
            .task(id: changeToken) {
                pushNow()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .watchSyncRequested)
            ) { _ in
                pushNow()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: AppConstants.dataDidUpdate)
            ) { _ in
                pushNow()
            }
            #if DEBUG
            // Debug time override changes don't touch courses/AppState, so
            // `changeToken` won't re-fire. Push explicitly so the watch
            // gets the new override (or the cleared state) immediately.
            .onReceive(
                NotificationCenter.default.publisher(for: DebugClockController.didChangeNotification)
            ) { _ in
                pushNow()
            }
            #endif
    }

    /// Stable identity that flips whenever AppState-tracked state changes.
    /// `.task(id:)` fires once on appear (initial push) and again on any
    /// login / accent / language change. Course-list changes route through
    /// `AppConstants.dataDidUpdate` instead — `DataCache` writes aren't
    /// observable, so a digest here would just be a stale snapshot.
    private var changeToken: String {
        "\(appState.accentColorHex)|\(appState.appLanguage)|\(appState.isNTUSTLoggedIn)"
    }

    private func pushNow() {
        let accentHex = String(format: "#%06X", UInt(bitPattern: Int(appState.accentColorHex)) & 0xFFFFFF)
        let lang = appState.appLanguage == LanguageManager.system ? nil : appState.appLanguage
        let customNames = DataCache.shared.loadCourseCustomNames()
        coordinator.scheduleDebouncedPush(
            courses: courseProvider.currentCourses(),
            customNames: customNames,
            accentHex: accentHex,
            loggedIn: appState.isNTUSTLoggedIn,
            languageTag: lang
        )
    }
}
