import SwiftUI

/// Hidden view that pushes a fresh `WatchSnapshot` whenever the phone's courses, accent color,
/// language or login flag change. Living in the view tree lets `AppState`'s `@Observable`
/// tracking drive the pushes; `TigerDuckApp` passes in the activated `WatchSyncCoordinator`.
///
/// Courses come from `CanonicalCourseProvider`: the course list lives in `DataCache` files,
/// never in the model container, so a SwiftData `@Query` would return `[]`. The bridge re-reads
/// on `AppConstants.dataDidUpdate`, posted by `AppState.backgroundSync` after
/// `DataCache.saveCourses`.
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
        let accentHex = String(format: "#%06X", UInt(bitPattern: Int(appState.accentColorHex)) & 0xFFFFFF)
        let lang = appState.appLanguage == LanguageManager.system ? nil : appState.appLanguage
        let customNames = DataCache.shared.loadCourseCustomNamesFlat()
        coordinator.scheduleDebouncedPush(
            courses: courseProvider.currentCourses(),
            customNames: customNames,
            accentHex: accentHex,
            loggedIn: appState.authService.hasStoredCredentials,
            languageTag: lang,
            visualPreset: appState.visualPreset
        )
        // Idempotent re-push, so a TTL-purged watch, or one that was off when the user logged
        // in on the phone, gets credentials back the next time the phone foregrounds. The epoch
        // is the last one sent, so a watch that has them rejects it as a replay.
        WatchLibraryCredentialBroadcaster.shared.republishIfCredentialed()
    }
}
