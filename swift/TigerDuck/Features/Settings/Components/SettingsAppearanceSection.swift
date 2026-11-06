import Defaults
import SwiftUI
import TigerDuckCore

struct SettingsAppearanceSection: View {
    let sheets: SettingsSheetState

    @Environment(AppPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Default(.appAppearance) private var appearance

    var body: some View {
        @Bindable var preferences = preferences
        Section(String(localized: "settings_section_appearance")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(SettingsRow.accentColor.label)
                HStack(spacing: 12) {
                    ForEach(AppPreferences.themeColors, id: \.hex) { theme in
                        swatch(theme.hex, name: theme.nameKey)
                    }
                    CustomAccentButton(preferences: preferences, size: 28) {
                        sheets.showingAccentEditor = true
                    }
                }
            }
            .settingsRow(.accentColor)
            Toggle(SettingsRow.accentGradientOnDevices.label, isOn: $preferences.accentGradientOnDevices)
                .settingsRow(.accentGradientOnDevices)
            Picker(SettingsRow.visualPreset.label, selection: $preferences.visualPreset) {
                ForEach(VisualPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .settingsRow(.visualPreset)
            Picker(SettingsRow.colorTheme.label, selection: $appearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            .settingsRow(.colorTheme)
            Button(SettingsRow.tabBar.label) {
                sheets.showingTabEditor = true
            }
            .settingsRow(.tabBar)
        }
    }

    private func swatch(_ hex: Int, name: LocalizedStringResource) -> some View {
        let isShown = preferences.accent == AccentGradient(color: hex)
        return Button {
            withAnimation(reduceMotion ? nil : .smoothSpring) {
                preferences.accent = AccentGradient(color: hex)
            }
        } label: {
            Circle()
                .fill(Color(hex: UInt(hex)))
                .frame(width: 28, height: 28)
                .overlay {
                    if isShown {
                        Image(systemName: "checkmark")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(isShown ? .isSelected : [])
    }
}
