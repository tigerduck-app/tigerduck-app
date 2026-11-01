import Defaults
import SwiftUI

// The page settings that the Mac's settings window shows too, under a header naming the page.

struct HomeDisplayToggles: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        Toggle(SettingsRow.showFullDueDate.label, isOn: $preferences.showAbsoluteAssignmentTime)
        #if os(iOS)
        Toggle(SettingsRow.invertSlider.label, isOn: $preferences.invertSliderDirection)
        #endif
    }
}

struct ClassTableDisplayToggles: View {
    @Bindable var preferences: AppPreferences
    @Default(.outlineRequiredCourses) private var outlineRequiredCourses
    #if os(iOS)
    @Default(.pinTodayCoursesOnClassTable) private var pinTodayCourses
    #endif

    var body: some View {
        #if os(iOS)
        Toggle(SettingsRow.pinTodayCourses.label, isOn: $pinTodayCourses)
        #endif
        Toggle(SettingsRow.showClassroom.label, isOn: $preferences.showClassroomInClassTable)
        Toggle(SettingsRow.outlineRequiredCourses.label, isOn: $outlineRequiredCourses)
        Toggle(SettingsRow.showAllPeriods.label, isOn: $preferences.alwaysShowAllPeriods)
    }
}

struct CourseAbbreviationSection: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        Section(String(localized: "settings_section_abbreviation")) {
            Toggle(SettingsRow.englishCourseNames.label, isOn: $preferences.useEnglishCourseAbbreviation)
            Toggle(SettingsRow.englishClassroomNames.label, isOn: $preferences.useEnglishClassroomAbbreviation)
            if preferences.useEnglishClassroomAbbreviation {
                Picker(SettingsRow.mandarinClassroomNames.label, selection: $preferences.classroomMandarinDisplay) {
                    Text(String(localized: "settings_classroom_mandarin_display_original")).tag("original")
                    Text(String(localized: "settings_classroom_mandarin_display_pinyin")).tag("pinyin")
                    Text(String(localized: "settings_classroom_mandarin_display_translated")).tag("translated")
                }
                // On iOS the Form default, `.menu`, sizes the row for one line and clips a label
                // that wraps; `.navigationLink` gives the row the label's height.
                #if os(iOS)
                .pickerStyle(.navigationLink)
                #else
                .pickerStyle(.menu)
                #endif
            }
        }
    }
}

struct ReassignCourseColorsButton: View {
    @Environment(AppEnvironment.self) private var app: AppEnvironment?
    @State private var isConfirming = false

    var body: some View {
        Button {
            isConfirming = true
        } label: {
            Text(SettingsRow.reassignCourseColors.label)
                .foregroundStyle(.primary)
        }
        .alert(String(localized: "settings_reset_course_colors_confirm_title"), isPresented: $isConfirming) {
            Button(String(localized: "action_confirm"), role: .destructive) {
                guard let app else { return }
                app.edits.reassignAllCourseColors(for: app.authService.session.currentSignIn)
            }
            Button(String(localized: "action_cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings_reset_course_colors_confirm_message"))
        }
    }
}
