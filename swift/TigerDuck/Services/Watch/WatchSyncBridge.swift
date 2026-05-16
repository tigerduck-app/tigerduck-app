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
    /// is handled inside the coordinator. Course rows must include the
    /// user-visible fields (name/alias/instructor/schedule/classroom map)
    /// so that an in-place edit reruns the push even when the array length
    /// is unchanged.
    private var changeToken: String {
        let courseDigest = courses
            .map { c in
                [
                    c.courseNo,
                    c.courseName,
                    c.customName ?? "",
                    c.instructor,
                    c.scheduleJSON,
                    c.classroomMapJSON,
                ].joined(separator: "·")
            }
            .sorted()
            .joined(separator: ";")
        return "\(courseDigest)|\(appState.accentColorHex)|\(appState.appLanguage)|\(appState.isNTUSTLoggedIn)"
    }

    private func pushNow() {
        let accentHex = String(format: "#%06X", UInt(bitPattern: Int(appState.accentColorHex)) & 0xFFFFFF)
        let lang = appState.appLanguage == LanguageManager.system ? nil : appState.appLanguage
        // `customName` on SDCourse is `@Transient` and not populated for every
        // instance returned by `@Query`, so load the canonical alias overlay
        // here and pass it through — matches the iOS widget snapshot path.
        let customNames = DataCache.shared.loadCourseCustomNames()
        coordinator.scheduleDebouncedPush(
            courses: courses,
            customNames: customNames,
            accentHex: accentHex,
            loggedIn: appState.isNTUSTLoggedIn,
            languageTag: lang
        )
    }
}
