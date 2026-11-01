import SwiftUI

extension View {
    /// Sets the `SettingsState` and the `AppPreferences` that the Settings views read, from the app.
    func settingsEnvironment() -> some View {
        modifier(SettingsEnvironment())
    }
}

extension SettingsState {
    init(app: AppEnvironment, isCloudSyncOn: Bool) {
        let mail = MailAccountManager.shared
        self.init(
            school: Account(isSignedIn: app.authService.hasStoredCredentials, name: app.authService.storedStudentId),
            library: Account(isSignedIn: app.library.isLoggedIn, name: app.library.username),
            mail: Self.mailAccount(mail),
            mailSignInFailed: mail.authFailed,
            isCloudSyncOn: isCloudSyncOn,
            isChineseUI: !LanguageManager.isCurrentLanguageNonChinese(appLanguage: app.preferences.appLanguage),
            usesEnglishClassroomNames: app.preferences.useEnglishClassroomAbbreviation,
            hasFlipToLibrary: LibrarySettingsView.isAvailable,
            hasSchoolMail: SchoolMailAvailability.isEnabled,
            hasWhatsNew: app.updateNotifyCoordinator.hasWhatsNewContent(in: app),
            isCheckingForUpdate: app.updateNotifyCoordinator.isCheckingForUpdate
        )
    }

    static func mailAccount(_ mail: MailAccountManager) -> Account {
        Account(isSignedIn: mail.isLoggedIn, name: mail.studentID)
    }
}

private struct SettingsEnvironment: ViewModifier {
    @Environment(AppEnvironment.self) private var app: AppEnvironment?
    /// Observed: a bare `Defaults[...]` read is one SwiftUI never subscribes to.
    @AccountDefault(.cloudSyncEnabled) private var cloudSyncEnabled

    func body(content: Content) -> some View {
        if let app {
            content
                .environment(\.settingsState, SettingsState(app: app, isCloudSyncOn: cloudSyncEnabled))
                .environment(app.preferences)
        } else {
            // A unit test has no app and sets both above the view.
            content
        }
    }
}
