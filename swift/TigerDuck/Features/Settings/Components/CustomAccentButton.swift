import SwiftUI
import TigerDuckCore

struct CustomAccentButton: View {
    let preferences: AppPreferences
    let size: CGFloat
    let action: () -> Void

    private static let wheel = [0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x5AC8FA, 0x007AFF, 0xAF52DE, 0xFF2D55, 0xFF3B30]
        .map { Color(hex: UInt($0)) }

    private var isSelected: Bool {
        let accent = preferences.accent
        return accent.isGradient || !AppPreferences.themeColors.contains { $0.hex == accent.first }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(AngularGradient(colors: Self.wheel, center: .center))
                Circle().fill(.white).padding(size * 0.09)
                Circle().fill(preferences.accentStyle).padding(size * 0.16)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2.bold())
                        .foregroundStyle(AccentContrast.whiteReads(on: preferences.accentColorHex) ? Color.white : Color.black)
                }
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "settings_accent_gradient_custom"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
