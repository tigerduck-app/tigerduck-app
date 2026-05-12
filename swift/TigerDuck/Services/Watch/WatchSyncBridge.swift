import SwiftUI
import SwiftData

/// Hidden view that observes the phone's user-facing state (courses, accent
/// color, language, login flag) and pushes a fresh `WatchSnapshot` whenever
/// any of them changes. Lives in the view tree so SwiftData `@Query` and the
/// `@Observable` `AppState` reactivity drive pushes for free — TigerDuckApp
/// hands us the activated `WatchSyncCoordinator` via init.
struct WatchSyncBridge: View {

    @Environment(AppState.self) private var appState
    @Query private var courses: [SDCourse]

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
                NotificationCenter.default.publisher(for: .watchSyncRequested)
            ) { _ in
                pushNow()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: AppConstants.dataDidUpdate)
            ) { _ in
                pushNow()
            }
    }

    /// Combined value whose stable identity flips whenever any tracked
    /// piece of state changes. `.task(id:)` re-runs on change, debouncing
    /// is handled inside the coordinator.
    private var changeToken: String {
        "\(courses.count)|\(appState.accentColorHex)|\(appState.appLanguage)|\(appState.isNTUSTLoggedIn)"
    }

    private func pushNow() {
        let accentHex = String(format: "#%06X", UInt(bitPattern: Int(appState.accentColorHex)) & 0xFFFFFF)
        let lang = appState.appLanguage == LanguageManager.system ? nil : appState.appLanguage
        coordinator.scheduleDebouncedPush(
            courses: courses,
            accentHex: accentHex,
            loggedIn: appState.isNTUSTLoggedIn,
            languageTag: lang
        )
    }
}
