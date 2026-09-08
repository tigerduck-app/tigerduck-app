#if os(macOS)
import SwiftUI
import AppKit

/// General tab — language, what the schedule shows, name-abbreviation
/// toggles, and how links open. One of the six tabs assembled by
/// `MacSettingsScene`.
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

                // Directly under the in-app picker because the two answer
                // the same question, and the picker alone cannot: its
                // "follow system" option defers to the per-app Language &
                // Region pane in System Settings, which is the only place
                // macOS actually applies the system locale. Mirrors the
                // iPhone's language redirect.
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack {
                        Text(String(localized: "settings_system_language"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            // The same two toggles in the same order as the iPhone's
            // Display section. The Mac had one of them filed under
            // Appearance > Schedule, alone, and the other nowhere at all —
            // even though `MacClassTableView` has always read it.
            Section(String(localized: "settings_section_display")) {
                Toggle(String(localized: "settings_show_absolute_assignment_time"), isOn: $state.showAbsoluteAssignmentTime)
                Toggle(String(localized: "settings_always_show_periods_abc"), isOn: $state.alwaysShowPeriodsABC)
            }

            Section(String(localized: "settings_section_abbreviation")) {
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
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif
