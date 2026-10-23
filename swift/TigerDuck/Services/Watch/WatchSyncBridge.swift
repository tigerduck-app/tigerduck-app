import SwiftUI

struct WatchSyncBridge: View {

    @Environment(AppState.self) private var appState

    let coordinator: WatchSyncCoordinator

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: changeToken) {
                pushNow()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: AppConstants.dataDidUpdate)
            ) { _ in
                pushNow()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: AppConstants.holidayNotifyDidChange)
            ) { _ in
                pushNow()
            }
            #if DEBUG
            .onReceive(
                NotificationCenter.default.publisher(for: DebugClockController.didChangeNotification)
            ) { _ in
                pushNow()
            }
            #endif
    }

    private var changeToken: String {
        "\(appState.accentColorHex)|\(appState.appLanguage)|\(appState.authService.hasStoredCredentials)|\(appState.visualPreset.rawValue)"
    }

    private func pushNow() {
        coordinator.pushCurrentState()
    }
}

extension WatchSyncCoordinator.Payload {
    init(appState: AppState) {
        self.init(
            courses: CanonicalCourseProvider().currentCourses(),
            customNames: DataCache.shared.loadCourseCustomNamesFlat(),
            accentHex: String(format: "#%06X", UInt(bitPattern: Int(appState.accentColorHex)) & 0xFFFFFF),
            loggedIn: appState.authService.hasStoredCredentials,
            languageTag: appState.appLanguage == LanguageManager.system ? nil : appState.appLanguage,
            visualPreset: appState.visualPreset,
            quietDays: WidgetSnapshotWriter.quietDayKeys()
        )
    }
}
