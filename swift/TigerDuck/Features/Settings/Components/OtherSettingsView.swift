import SwiftUI

/// Sub-page collecting the "miscellaneous" settings, behind a
/// NavigationLink in `SettingsView`'s "Other settings" section next to the
/// one into `LibrarySettingsView`, so the top-level list stays short. One
/// Section per group: course font size, slider direction, API endpoint,
/// course colours. Android's page has the same groups plus vibration,
/// screen rotation, colour theme and analytics, which iOS does not offer.
/// The links out are on `AboutOthersView`, under the About section.
struct OtherSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showReassignColorsConfirm = false

    var body: some View {
        @Bindable var appState = appState
        List {
            // Each group keeps its own Section so the cards stay visually
            // separated.
            Section {
                NavigationLink {
                    FontSizeSettingsView()
                } label: {
                    HStack {
                        Text(String(localized: "settings_font_size_title"))
                            .foregroundStyle(.primary)
                        Spacer()
                        // Locale-aware decimal separator: en "1.20×",
                        // de/fr/es/it "1,20×". `String(format:)` would
                        // be POSIX-only and break the non-period locales.
                        Text(CourseCardFontScale
                            .normalize(appState.courseCardFontScale)
                            .formatted(.number.precision(.fractionLength(2))) + "×")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } footer: {
                Text(String(localized: "settings_font_size_summary"))
            }
            Section {
                Toggle(String(localized: "settings_invert_slider_direction"), isOn: $appState.invertSliderDirection)
            }
            Section {
                NavigationLink(String(localized: "settings_api_endpoint")) {
                    DebugEndpointView()
                }
            }
            Section {
                Button {
                    showReassignColorsConfirm = true
                } label: {
                    Text(String(localized: "settings_reset_course_colors"))
                        .foregroundStyle(.primary)
                }
            }
        }
        .navigationTitle(String(localized: "settings_section_other_settings"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            String(localized: "settings_reset_course_colors_confirm_title"),
            isPresented: $showReassignColorsConfirm
        ) {
            Button(String(localized: "action_confirm"), role: .destructive) {
                appState.reassignAllCourseColors()
            }
            Button(String(localized: "action_cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings_reset_course_colors_confirm_message"))
        }
    }
}
