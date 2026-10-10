#if os(macOS)
import SwiftUI
import AppKit

/// General tab — language, what the schedule shows, name-abbreviation
/// toggles, and how links open. One of the six tabs assembled by
/// `MacSettingsScene`.
struct MacGeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    /// Every language the app ships, in the order of their own names.
    private static let languageTags: [String] = LanguageManager.supportedLocaleTags()
        .sorted {
            LanguageManager.displayName(for: $0)
                .localizedStandardCompare(LanguageManager.displayName(for: $1)) == .orderedAscending
        }

    var body: some View {
        @Bindable var state = appState
        Form {
            Section(String(localized: "desktop_settings_section_interface")) {
                Picker(String(localized: "settings_language"), selection: $state.appLanguage) {
                    Text(String(localized: "settings_language_follow_system")).tag(LanguageManager.system)
                    ForEach(Self.languageTags, id: \.self) { tag in
                        Text(LanguageManager.displayName(for: tag)).tag(tag)
                    }
                }
                .pickerStyle(.menu)

                // Under the in-app picker, which cannot do this alone: its "follow system" option
                // defers to the per-app Language & Region pane in System Settings, the only place
                // macOS applies the system locale. Mirrors the iPhone's language redirect.
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

            // The same toggles in the same order as the iPhone's Display section.
            Section(String(localized: "settings_section_display")) {
                Toggle(String(localized: "settings_show_absolute_assignment_time"), isOn: $state.showAbsoluteAssignmentTime)
                Toggle(
                    String(localized: "settings_show_classroom_on_class_table"),
                    isOn: $state.showClassroomInClassTable
                )
                Toggle(String(localized: "settings_always_show_periods_abc"), isOn: $state.alwaysShowAllPeriods)
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
                // No first-party Moodle app exists for Mac, but the iPad app from the Mac App
                // Store registers `moodlemobile://`, so its users can opt in. The default stays
                // `.browser`: without the app, that URL fails with "no app handles this URL".
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
