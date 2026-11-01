import SwiftUI

extension View {
    func settingsEnvironment() -> some View {
        modifier(SettingsEnvironment())
    }
}

extension SettingsState {
    init(app: AppEnvironment, isCloudSyncOn: Bool) {
        self.init(school: app.authService, library: app.library, mail: .shared, isCloudSyncOn: isCloudSyncOn)
        isChineseUI = !LanguageManager.isCurrentLanguageNonChinese(appLanguage: app.preferences.appLanguage)
        usesEnglishClassroomNames = app.preferences.useEnglishClassroomAbbreviation
        hasFlipToLibrary = LibrarySettingsView.isAvailable
        hasSchoolMail = SchoolMailAvailability.isEnabled
        hasWhatsNew = app.updateNotifyCoordinator.hasWhatsNewContent(in: app)
        isCheckingForUpdate = app.updateNotifyCoordinator.isCheckingForUpdate
    }

    init(school: AuthService, library: LibraryAccountStatus, mail: MailAccountManager, isCloudSyncOn: Bool) {
        self.init(
            school: Account(isSignedIn: school.hasStoredCredentials, name: school.storedStudentId),
            library: Account(isSignedIn: library.isLoggedIn, name: library.username),
            mail: Self.mailAccount(mail),
            mailSignInFailed: mail.authFailed,
            isCloudSyncOn: isCloudSyncOn
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
            content
        }
    }
}
