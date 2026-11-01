#if os(macOS)
import Defaults
import SwiftUI

struct MacAppearanceSettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @Default(.appAppearance) private var appearance

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
                    CustomAccentPicker(preferences: app.preferences, size: 32)
                        .padding(4)
                }
                .padding(.vertical, 4)
            }

            Section {
                ReassignCourseColorsButton()
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
