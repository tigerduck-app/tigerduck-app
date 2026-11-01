#if os(macOS)
import Defaults
import SwiftUI

struct MacAppearanceSettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @Default(.appAppearance) private var appearance
    @State private var isConfirmingReassign = false

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "settings_color_theme"), selection: $appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
            }

            Section(String(localized: "settings_accent_color")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(AppPreferences.themeColors, id: \.hex) { entry in
                        accentSwatch(hex: entry.hex, nameKey: entry.nameKey)
                    }
                    CustomAccentPicker(app: app, size: 32)
                        .padding(4)
                }
                .padding(.vertical, 4)
            }

            Section {
                Button(String(localized: "settings_reset_course_colors")) {
                    isConfirmingReassign = true
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(
            String(localized: "settings_reset_course_colors_confirm_title"),
            isPresented: $isConfirmingReassign
        ) {
            Button(String(localized: "action_confirm"), role: .destructive) {
                app.edits.reassignAllCourseColors(for: app.authService.session.currentSignIn)
            }
            Button(String(localized: "action_cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings_reset_course_colors_confirm_message"))
        }
    }

    private func accentSwatch(hex: Int, nameKey: LocalizedStringResource) -> some View {
        let color = Color(hex: UInt(bitPattern: Int(hex)))
        let isSelected = AccentPreview.shared.shownHex(saved: app.preferences.accentColorHex) == hex
        return Button {
            AccentPreview.shared.clear()
            app.preferences.accentColorHex = hex
        } label: {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 32, height: 32)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(4)
            .background(
                Circle()
                    .stroke(isSelected ? color : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(nameKey))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#endif
