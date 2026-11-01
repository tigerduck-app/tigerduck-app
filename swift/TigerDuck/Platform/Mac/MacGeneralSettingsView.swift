#if os(macOS)
import SwiftUI
import AppKit

struct MacGeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var app

    private static let languageTags: [String] = LanguageManager.supportedLocaleTags()
        .sorted {
            LanguageManager.displayName(for: $0)
                .localizedStandardCompare(LanguageManager.displayName(for: $1)) == .orderedAscending
        }

    var body: some View {
        @Bindable var preferences = app.preferences
        Form {
            Section(String(localized: "desktop_settings_section_interface")) {
                Picker(String(localized: "settings_language"), selection: $preferences.appLanguage) {
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

            Section(String(localized: PageSettings.home.titleKey)) {
                HomeDisplayToggles(preferences: preferences)
            }

            Section(String(localized: PageSettings.classTable.titleKey)) {
                ClassTableDisplayToggles(preferences: preferences)
            }

            CourseAbbreviationSection(preferences: preferences)

            Section(String(localized: "desktop_settings_section_links")) {
                Picker(String(localized: "desktop_settings_moodle_open_in"), selection: $preferences.macMoodleOpenTarget) {
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
