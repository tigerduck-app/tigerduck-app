#if os(macOS)
import SwiftUI
import AppKit

/// General tab — language, name-abbreviation toggles, and how links open.
/// One of the six tabs assembled by `MacSettingsScene`.
struct MacGeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Form {
            Section(String(localized: "desktop_settings_section_interface")) {
                Picker(String(localized: "settings_language"), selection: $state.appLanguage) {
                    Text(String(localized: "settings_language_follow_system")).tag("system")
                    Text(String(localized: "settings_language_traditional_chinese")).tag("zh-Hant")
                    Text(String(localized: "settings_language_english")).tag("en")
                }
                .pickerStyle(.menu)
            }

            Section(String(localized: "desktop_settings_section_course_display")) {
                Toggle(String(localized: "settings_use_english_course_abbreviation"), isOn: $state.useEnglishCourseAbbreviation)
                Toggle(String(localized: "settings_use_english_classroom_abbreviation"), isOn: $state.useEnglishClassroomAbbreviation)
                Picker(String(localized: "settings_classroom_mandarin_display"), selection: $state.classroomMandarinDisplay) {
                    Text(String(localized: "settings_classroom_mandarin_display_original")).tag("original")
                    Text(String(localized: "settings_classroom_mandarin_display_pinyin")).tag("pinyin")
                    Text(String(localized: "settings_classroom_mandarin_display_translated")).tag("translated")
                }
                .pickerStyle(.menu)
            }

            Section(String(localized: "desktop_settings_section_links")) {
                // No first-party Moodle Mac app exists, but the iPad
                // Moodle app installed via Mac App Store registers
                // `moodlemobile://`, so users who chose to install it can
                // opt into the deep link. Default stays `.browser` —
                // sending the user to `moodlemobile://` with no app
                // installed yields "no app handles this URL".
                Picker(String(localized: "desktop_settings_moodle_open_in"), selection: $state.macMoodleOpenTarget) {
                    Text(String(localized: "desktop_settings_moodle_open_in_browser")).tag(MoodleOpenTarget.browser)
                    Text(String(localized: "desktop_settings_moodle_open_in_app")).tag(MoodleOpenTarget.app)
                }
                .pickerStyle(.menu)
            }

            // Mirror of the iPhone language redirect: the per-app
            // Language & Region pane in System Settings is where macOS
            // actually applies the system locale. Re-uses the iPhone
            // keys (`feature_category_language`, `settings_language`) so
            // we don't fork translations for the same idea.
            Section(String(localized: "feature_category_language")) {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack {
                        Text(String(localized: "settings_language"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif
