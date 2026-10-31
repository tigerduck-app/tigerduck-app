import Foundation

extension WatchSyncCoordinator.Payload {
    init(app: AppEnvironment) {
        self.init(
            courses: CanonicalCourseProvider().currentCourses(),
            customNames: CourseStore.shared.loadCourseCustomNamesFlat(),
            accentHex: String(format: "#%06X", UInt(bitPattern: Int(app.preferences.accentColorHex)) & 0xFFFFFF),
            loggedIn: app.authService.hasStoredCredentials,
            languageTag: app.preferences.appLanguage == LanguageManager.system ? nil : app.preferences.appLanguage,
            visualPreset: app.preferences.visualPreset,
            quietDays: WidgetSnapshotWriter.quietDayKeys(),
            changes: .cached
        )
    }
}
