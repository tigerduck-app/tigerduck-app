import Defaults
import SwiftUI

struct MoodlePageSettingsView: View {
    @Environment(\.settingsState) private var state
    @Default(.moodleOpenTarget) private var openTarget

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
                if SettingsRow.moodleOpenIn.isShown(in: state) {
                    Picker(SettingsRow.moodleOpenIn.label, selection: $openTarget) {
                        Text(String(localized: "settings_moodle_open_in_app")).tag(MoodleOpenTarget.app)
                        Text(String(localized: "settings_browser_in_app")).tag(MoodleOpenTarget.browser)
                    }
                    .pickerStyle(.menu)
                    .settingsRow(.moodleOpenIn)
                }
            }
            StorageKindSection(kind: .moodleFiles)
        }
    }
}
