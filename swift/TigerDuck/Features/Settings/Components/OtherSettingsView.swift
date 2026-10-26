import SwiftUI

struct OtherSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showReassignColorsConfirm = false
    @State private var storageBytes: Int?

    var body: some View {
        @Bindable var appState = appState
        List {
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
            Section {
                NavigationLink {
                    StorageSettingsView()
                } label: {
                    LabeledContent(String(localized: "settings_storage_title")) {
                        Text(storageBytes.map(StorageSizes.text) ?? "…")
                            .monospacedDigit()
                    }
                }
                .task { storageBytes = await StorageCleaner.live.measure().total }
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
