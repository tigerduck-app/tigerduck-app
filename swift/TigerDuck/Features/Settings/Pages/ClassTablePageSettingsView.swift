import SwiftUI

struct ClassTablePageSettingsView: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.settingsState) private var state

    var body: some View {
        List {
            if SettingsRow.classTableList.isShown(in: state) {
                Section {
                    NavigationLink(SettingsRow.classTableList.label) {
                        AppDestination { app in
                            ClassTableListView(
                                store: .shared,
                                userName: ClassTableSwitcherEntry.userName(studentId: app.authService.storedStudentId)
                            )
                        }
                    }
                    .settingsRow(.classTableList)
                }
            }
            Section {
                ClassTableDisplayToggles(preferences: preferences)
            }
            Section {
                NavigationLink {
                    FontSizeSettingsView()
                } label: {
                    LabeledContent(SettingsRow.courseNameSize.label) {
                        // Locale-aware decimal separator: en "1.20×", de "1,20×".
                        Text(CourseCardFontScale
                            .normalize(preferences.courseCardFontScale)
                            .formatted(.number.precision(.fractionLength(2))) + "×")
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            } footer: {
                Text(String(localized: "settings_font_size_summary"))
            }
            Section {
                NavigationLink(SettingsRow.classReminders.label) {
                    AppDestination { ClassReminderSettingsView(store: $0.liveActivity.preferences) }
                }
                .settingsRow(.classReminders)
            }
            if SettingsRow.englishCourseNames.isShown(in: state) {
                CourseAbbreviationSection(preferences: preferences)
            }
            Section {
                ReassignCourseColorsButton()
            }
        }
    }
}
