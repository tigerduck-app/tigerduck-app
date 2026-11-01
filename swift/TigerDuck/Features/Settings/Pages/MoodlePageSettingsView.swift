import SwiftUI

struct MoodlePageSettingsView: View {
    var body: some View {
        List {
            Section {
                NavigationLink(SettingsRow.moodleNotifications.label) {
                    AppDestination { app in
                        MoodleNotificationSettingsView(settings: MoodleNotificationSettings(
                            signIn: app.authService.session.currentSignIn,
                            api: .live(chinese: !LanguageManager.isCurrentLanguageNonChinese(
                                appLanguage: app.preferences.appLanguage
                            ))
                        ), account: app.authService.session)
                    }
                }
                .settingsRow(.moodleNotifications)
            }
            StorageKindSection(kind: .moodleFiles)
        }
    }
}
