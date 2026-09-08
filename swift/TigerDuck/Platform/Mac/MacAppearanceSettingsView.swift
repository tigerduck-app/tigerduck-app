#if os(macOS)
import SwiftUI

/// Appearance tab — accent colour swatches and the course palette.
/// One of the tabs assembled by `MacSettingsScene`.
struct MacAppearanceSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var isConfirmingReassign = false

    var body: some View {
        Form {
            Section(String(localized: "settings_accent_color")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(AppState.themeColors, id: \.hex) { entry in
                        accentSwatch(hex: entry.hex)
                    }
                }
                .padding(.vertical, 4)
            }

            // Course colours are assigned automatically and can drift into
            // near-neighbours as courses come and go across semesters;
            // this is the way back to a clean spread. Confirmed first —
            // it discards every colour the user picked by hand.
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

    private func accentSwatch(hex: Int) -> some View {
        let color = Color(hex: UInt(bitPattern: Int(hex)))
        let isSelected = appState.accentColorHex == hex
        return Button {
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
    }
}

#endif
