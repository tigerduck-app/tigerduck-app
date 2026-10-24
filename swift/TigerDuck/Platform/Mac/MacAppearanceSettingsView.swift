#if os(macOS)
import SwiftUI

struct MacAppearanceSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var isConfirmingReassign = false

    var body: some View {
        Form {
            Section(String(localized: "settings_accent_color")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(AppState.themeColors, id: \.hex) { entry in
                        accentSwatch(hex: entry.hex, nameKey: entry.nameKey)
                    }
                    CustomAccentPicker(appState: appState, size: 32)
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
                appState.reassignAllCourseColors()
            }
            Button(String(localized: "action_cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings_reset_course_colors_confirm_message"))
        }
    }

    private func accentSwatch(hex: Int, nameKey: String) -> some View {
        let color = Color(hex: UInt(bitPattern: Int(hex)))
        let isSelected = AccentPreview.shared.shownHex(saved: appState.accentColorHex) == hex
        return Button {
            AccentPreview.shared.clear()
            appState.accentColorHex = hex
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
        .accessibilityLabel(Text(String(localized: String.LocalizationValue(nameKey))))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#endif
