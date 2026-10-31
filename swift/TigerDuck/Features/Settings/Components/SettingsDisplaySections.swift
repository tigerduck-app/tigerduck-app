import Defaults
import SwiftUI

/// The settings list's customisation, display, address bar and abbreviation sections.
struct SettingsDisplaySections: View {
    let sheets: SettingsSheetState

    @Environment(AppEnvironment.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Default(.outlineRequiredCourses) private var outlineRequiredCourses
    @Default(.pinTodayCoursesOnClassTable) private var pinTodayCoursesOnClassTable
    @Default(.appAppearance) private var appearance
    @Default(.browserAddressBar) private var browserAddressBar

    var body: some View {
        @Bindable var preferences = app.preferences
        Section(String(localized: "settings_section_custom")) {
            Button(String(localized: "tab_editor_title")) {
                sheets.showingTabEditor = true
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "settings_accent_color"))
                HStack(spacing: 12) {
                    ForEach(AppPreferences.themeColors, id: \.hex) { theme in
                        Button {
                            withAnimation(reduceMotion ? nil : .smoothSpring) {
                                AccentPreview.shared.clear()
                                app.preferences.accentColorHex = theme.hex
                            }
                        } label: {
                            Circle()
                                .fill(Color(hex: UInt(theme.hex)))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if AccentPreview.shared.shownHex(saved: app.preferences.accentColorHex) == theme.hex {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(String(localized: String.LocalizationValue(theme.nameKey))))
                        .accessibilityAddTraits(AccentPreview.shared.shownHex(saved: app.preferences.accentColorHex) == theme.hex ? .isSelected : [])
                    }
                    CustomAccentPicker(app: app, size: 28)
                }
            }
        }

        Section(String(localized: "settings_section_display")) {
            Picker(String(localized: "settings_visual_preset_label"), selection: $preferences.visualPreset) {
                ForEach(VisualPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            Picker(String(localized: "settings_color_theme"), selection: $appearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            Toggle(String(localized: "settings_show_absolute_assignment_time"), isOn: $preferences.showAbsoluteAssignmentTime)
            Toggle(
                String(localized: "settings_pin_today_courses_on_class_table"),
                isOn: $pinTodayCoursesOnClassTable
            )
            Toggle(
                String(localized: "settings_show_classroom_on_class_table"),
                isOn: $preferences.showClassroomInClassTable
            )
            Toggle(String(localized: "settings_outline_required_courses"), isOn: $outlineRequiredCourses)
            Toggle(String(localized: "settings_always_show_periods_abc"), isOn: $preferences.alwaysShowAllPeriods)
        }

        Section(String(localized: "browser_address_bar")) {
            BrowserAddressBarPicker(selection: $browserAddressBar)
        }

        if LanguageManager.isCurrentLanguageNonChinese(appLanguage: app.preferences.appLanguage) {
            Section(String(localized: "settings_section_abbreviation")) {
                Toggle(
                    String(localized: "settings_use_english_course_abbreviation"),
                    isOn: $preferences.useEnglishCourseAbbreviation
                )
                Toggle(
                    String(localized: "settings_use_english_classroom_abbreviation"),
                    isOn: $preferences.useEnglishClassroomAbbreviation
                )
                if app.preferences.useEnglishClassroomAbbreviation {
                    // The Form default, `.menu`, sizes the row for one line, so a long
                    // localized label wraps to two lines and is clipped at the bottom.
                    // `.navigationLink` renders a real NavigationLink whose row fits the label.
                    Picker(
                        String(localized: "settings_classroom_mandarin_display"),
                        selection: $preferences.classroomMandarinDisplay
                    ) {
                        Text(String(localized: "settings_classroom_mandarin_display_original"))
                            .tag("original")
                        Text(String(localized: "settings_classroom_mandarin_display_pinyin"))
                            .tag("pinyin")
                        Text(String(localized: "settings_classroom_mandarin_display_translated"))
                            .tag("translated")
                    }
                    .pickerStyle(.navigationLink)
                }
            }
        }
    }
}
