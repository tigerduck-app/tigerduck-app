import SwiftUI

/// Hidden view that pushes a fresh `WatchSnapshot` whenever the phone's courses, accent color,
/// language or login flag change. Living in the view tree lets `AppState`'s `@Observable`
/// tracking drive the pushes; `TigerDuckApp` passes in the `WatchSyncCoordinator`, whose
/// payload source reads `WatchSyncCoordinator.Payload(appState:)`.
///
/// The bridge re-reads on `AppConstants.dataDidUpdate`, posted by `AppState.backgroundSync`
/// after `DataCache.saveCourses`. The Watch's own sync requests go to the coordinator.
struct WatchSyncBridge: View {

    @Environment(AppState.self) private var appState

    let coordinator: WatchSyncCoordinator

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

    /// Changes whenever AppState-tracked state does, so `.task(id:)` fires on appear and again
    /// on any login, accent, language or visual-preset change. Course-list changes come through
    /// `AppConstants.dataDidUpdate`: `DataCache` writes are not observable, so a digest here
    /// would be a stale snapshot.
    ///
    /// Uses `hasStoredCredentials`, not `isNTUSTLoggedIn`, so a transient cookie-TTL lapse
    /// during silent re-auth does not flip the token and push an empty logged-out payload to
    /// the watch. Mirrors the widget snapshot writer.
    private var changeToken: String {
        "\(appState.accentColorHex)|\(appState.appLanguage)|\(appState.authService.hasStoredCredentials)|\(appState.visualPreset.rawValue)"
    }

    private func pushNow() {
        coordinator.pushCurrentState()
    }
}

extension WatchSyncCoordinator.Payload {
    /// The phone's state as the Watch shows it. Courses come from `CanonicalCourseProvider`:
    /// the course list lives in `DataCache` files, never in the model container, so a
    /// SwiftData `@Query` would return `[]`.
    init(appState: AppState) {
        self.init(
            courses: CanonicalCourseProvider().currentCourses(),
            customNames: DataCache.shared.loadCourseCustomNamesFlat(),
            accentHex: String(format: "#%06X", UInt(bitPattern: Int(appState.accentColorHex)) & 0xFFFFFF),
            loggedIn: appState.authService.hasStoredCredentials,
            languageTag: appState.appLanguage == LanguageManager.system ? nil : appState.appLanguage,
            visualPreset: appState.visualPreset
        )
    }
}
