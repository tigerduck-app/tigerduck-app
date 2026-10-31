import Foundation

extension WatchSyncCoordinator.Payload {
    init(appState: AppState) {
        self.init(
            courses: CanonicalCourseProvider().currentCourses(),
            customNames: CourseStore.shared.loadCourseCustomNamesFlat(),
            accentHex: String(format: "#%06X", UInt(bitPattern: Int(appState.accentColorHex)) & 0xFFFFFF),
            loggedIn: appState.authService.hasStoredCredentials,
            languageTag: appState.appLanguage == LanguageManager.system ? nil : appState.appLanguage,
            visualPreset: appState.visualPreset,
            quietDays: WidgetSnapshotWriter.quietDayKeys(),
            changes: .cached
        )
    }
}
